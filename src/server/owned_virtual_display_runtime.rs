//! Asynchronous, single-screen owner coordinator for macOS CGVirtualDisplay.
//!
//! Requests are serialized on this dedicated worker. Blocking CoreGraphics
//! calls and display enumeration never run on a connection receive loop.

use super::display_service;
use super::owned_virtual_display::{
    normalize_target, ApplyAction, ApplyPlan, DisconnectPlan, LeaseBook, LeaseError,
    PendingFrameConfirmation, ReleasePlan, Target,
};
use hbb_common::message_proto::{
    OwnedVirtualDisplayCapabilities, OwnedVirtualDisplayOperation, OwnedVirtualDisplayRequest,
    OwnedVirtualDisplayResult, OwnedVirtualDisplayStatus, Resolution,
};
use hbb_common::protobuf::{Enum, MessageField};
use scrap::Display;
use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const COORDINATOR_OWNER_TOKEN: u64 = 0x4e52_4d4f_4e56_4450;
const DISPLAY_ENUMERATION_TIMEOUT: Duration = Duration::from_secs(5);
const DISPLAY_ENUMERATION_INTERVAL: Duration = Duration::from_millis(100);
const FRAME_CONFIRMATION_TIMEOUT: Duration = Duration::from_secs(12);
const CLEANUP_RETRY_INTERVAL: Duration = Duration::from_secs(1);

pub(super) type ResultEmitter = Arc<dyn Fn(OwnedVirtualDisplayResult) + Send + Sync + 'static>;

enum Command {
    Request {
        connection: u64,
        request: OwnedVirtualDisplayRequest,
        emit: ResultEmitter,
    },
    Disconnected {
        connection: u64,
    },
    Frame {
        connection: u64,
        display_index: i32,
        width: u32,
        height: u32,
    },
}

static MANAGER: OnceLock<Sender<Command>> = OnceLock::new();

fn manager_sender() -> &'static Sender<Command> {
    MANAGER.get_or_init(|| {
        let (sender, receiver) = mpsc::channel();
        if let Err(error) = thread::Builder::new()
            .name("owned-virtual-display".to_owned())
            .spawn(move || Manager::new().run(receiver))
        {
            log::error!("Failed to start owned display manager: {error}");
        }
        sender
    })
}

pub fn capabilities(control_allowed: bool) -> OwnedVirtualDisplayCapabilities {
    let native = crate::platform::macos::owned_virtual_display_capabilities();
    OwnedVirtualDisplayCapabilities {
        protocol_version: 1,
        supported: native.status
            != crate::platform::macos::OWNED_VIRTUAL_DISPLAY_RUNTIME_UNAVAILABLE
            && native.status != crate::platform::macos::OWNED_VIRTUAL_DISPLAY_INVALID_ARGUMENT,
        ready: native.status == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK,
        control_allowed,
        max_width: native.max_width,
        max_height: native.max_height,
        max_pixels: native.max_pixels,
        width_alignment: native.width_alignment,
        height_alignment: native.height_alignment,
        ..Default::default()
    }
}

pub(super) fn submit(
    connection: i32,
    request: OwnedVirtualDisplayRequest,
    emit: ResultEmitter,
) -> bool {
    manager_sender()
        .send(Command::Request {
            connection: connection.max(0) as u64,
            request,
            emit,
        })
        .is_ok()
}

pub(super) fn disconnected(connection: i32) {
    if let Some(sender) = MANAGER.get() {
        let _ = sender.send(Command::Disconnected {
            connection: connection.max(0) as u64,
        });
    }
}

pub(super) fn observe_frame(connection: i32, display_index: i32, width: u32, height: u32) {
    if let Some(sender) = MANAGER.get() {
        let _ = sender.send(Command::Frame {
            connection: connection.max(0) as u64,
            display_index,
            width,
            height,
        });
    }
}

pub(super) fn reject(
    request: &OwnedVirtualDisplayRequest,
    emit: &ResultEmitter,
    status: OwnedVirtualDisplayStatus,
    error_code: i32,
    message: &str,
) {
    emit_result(
        emit,
        result_for(
            request,
            status,
            request.lease_id,
            None,
            None,
            0,
            -1,
            message,
        )
        .with_error_code(error_code),
    );
}

#[derive(Clone, Copy, Debug)]
struct ActiveDisplay {
    display_id: u32,
    display_index: i32,
    width: u32,
    height: u32,
}

struct WaitingForFrame {
    confirmation: PendingFrameConfirmation,
    base: OwnedVirtualDisplayResult,
    emit: ResultEmitter,
    deadline: Instant,
}

struct Manager {
    leases: LeaseBook,
    active: Option<ActiveDisplay>,
    waiting: HashMap<u64, WaitingForFrame>,
    disconnected: HashSet<u64>,
    next_cleanup_attempt: Instant,
}

impl Manager {
    fn new() -> Self {
        Self {
            leases: LeaseBook::default(),
            active: None,
            waiting: HashMap::new(),
            disconnected: HashSet::new(),
            next_cleanup_attempt: Instant::now() + CLEANUP_RETRY_INTERVAL,
        }
    }

    fn run(mut self, receiver: Receiver<Command>) {
        loop {
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(Command::Request {
                    connection,
                    request,
                    emit,
                }) => self.handle_request(connection, request, emit),
                Ok(Command::Disconnected { connection }) => self.handle_disconnect(connection),
                Ok(Command::Frame {
                    connection,
                    display_index,
                    width,
                    height,
                }) => self.handle_frame(connection, display_index, width, height),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
            self.expire_frame_waiters();
            self.retry_disconnected_cleanup();
        }
    }

    fn handle_request(
        &mut self,
        connection: u64,
        request: OwnedVirtualDisplayRequest,
        emit: ResultEmitter,
    ) {
        let operation = match request.operation.enum_value() {
            Ok(OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_APPLY) => {
                OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_APPLY
            }
            Ok(OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_RELEASE) => {
                OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_RELEASE
            }
            _ => {
                emit_result(
                    &emit,
                    result_for(
                        &request,
                        OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_UNSUPPORTED,
                        request.lease_id,
                        None,
                        None,
                        0,
                        -1,
                        "unknown operation",
                    ),
                );
                return;
            }
        };

        match operation {
            OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_APPLY => {
                self.handle_apply(connection, request, emit)
            }
            OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_RELEASE => {
                self.handle_release(connection, request, emit)
            }
            _ => {}
        }
    }

    fn handle_apply(
        &mut self,
        connection: u64,
        request: OwnedVirtualDisplayRequest,
        emit: ResultEmitter,
    ) {
        let native_caps = crate::platform::macos::owned_virtual_display_capabilities();
        if native_caps.status != crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
            self.emit_failure(
                &request,
                &emit,
                if native_caps.status
                    == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_RUNTIME_UNAVAILABLE
                    || native_caps.status
                        == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_UNSAFE_TOPOLOGY
                {
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_UNSUPPORTED
                } else {
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_FAILED
                },
                native_caps.status,
                "owned display is not ready",
            );
            return;
        }
        let Some(requested) = request.requested.as_ref() else {
            self.emit_failure(
                &request,
                &emit,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_INVALID_TARGET,
                -2,
                "missing target",
            );
            return;
        };
        let Ok(width) = u32::try_from(requested.width) else {
            self.emit_failure(
                &request,
                &emit,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_INVALID_TARGET,
                -2,
                "invalid target width",
            );
            return;
        };
        let Ok(height) = u32::try_from(requested.height) else {
            self.emit_failure(
                &request,
                &emit,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_INVALID_TARGET,
                -2,
                "invalid target height",
            );
            return;
        };
        let target = match normalize_target(
            width,
            height,
            native_caps.max_width,
            native_caps.max_height,
            native_caps.max_pixels,
            native_caps.width_alignment,
            native_caps.height_alignment,
        ) {
            Ok(target) => target,
            Err(_) => {
                self.emit_failure(
                    &request,
                    &emit,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_INVALID_TARGET,
                    -2,
                    "target is outside advertised bounds",
                );
                return;
            }
        };
        let plan = match self.leases.plan_apply(
            connection,
            request.request_id,
            request.generation,
            request.lease_id,
            target,
        ) {
            Ok(plan) => plan,
            Err(error) => {
                self.emit_lease_error(&request, &emit, error);
                return;
            }
        };

        emit_result(
            &emit,
            result_for(
                &request,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_PENDING,
                plan.lease_id,
                Some(target),
                None,
                0,
                -1,
                "request accepted",
            ),
        );

        let applied = match plan.action {
            ApplyAction::Share => self.active.map(Ok).unwrap_or_else(|| {
                Err(crate::platform::macos::OWNED_VIRTUAL_DISPLAY_UNSAFE_TOPOLOGY)
            }),
            ApplyAction::Create | ApplyAction::Resize => {
                match crate::platform::macos::apply_owned_virtual_display(
                    COORDINATOR_OWNER_TOKEN,
                    plan.native_generation,
                    target.normalized_width,
                    target.normalized_height,
                ) {
                    Ok(native) => {
                        if native.pixel_width != target.normalized_width
                            || native.pixel_height != target.normalized_height
                        {
                            Err(crate::platform::macos::OWNED_VIRTUAL_DISPLAY_APPLY_FAILED)
                        } else {
                            self.wait_for_owned_display(
                                native.display_id,
                                native.pixel_width,
                                native.pixel_height,
                            )
                            .map(|display_index| ActiveDisplay {
                                display_id: native.display_id,
                                display_index,
                                width: native.pixel_width,
                                height: native.pixel_height,
                            })
                            .ok_or(crate::platform::macos::OWNED_VIRTUAL_DISPLAY_STABILITY_TIMEOUT)
                        }
                    }
                    Err(status) => Err(status),
                }
            }
        };

        let active = match applied {
            Ok(active) => active,
            Err(status) => {
                self.recover_failed_apply(plan, status);
                self.emit_failure(
                    &request,
                    &emit,
                    native_status_to_protocol(status),
                    status,
                    "native display apply failed or could not be observed",
                );
                return;
            }
        };
        self.leases.commit_apply(plan);
        self.active = Some(active);
        let applied_result = result_for(
            &request,
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_APPLIED,
            plan.lease_id,
            Some(target),
            Some((active.width, active.height)),
            active.display_id,
            active.display_index,
            "display mode applied and enumerated; waiting for frame",
        );
        self.arm_frame_confirmation(connection, request, emit, applied_result);
    }

    fn handle_release(
        &mut self,
        connection: u64,
        request: OwnedVirtualDisplayRequest,
        emit: ResultEmitter,
    ) {
        let plan = match self.leases.plan_release(
            connection,
            request.request_id,
            request.generation,
            request.lease_id,
        ) {
            Ok(plan) => plan,
            Err(error) => {
                self.emit_lease_error(&request, &emit, error);
                return;
            }
        };
        let Some(plan) = plan else {
            if request.lease_id == 0 {
                emit_result(
                    &emit,
                    result_for(
                        &request,
                        OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_CONFIRMED,
                        0,
                        None,
                        None,
                        0,
                        -1,
                        "no owned lease was active",
                    ),
                );
                return;
            }
            let Some(active) = self.active else {
                self.emit_failure(
                    &request,
                    &emit,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_FAILED,
                    -3,
                    "owned display state is missing",
                );
                return;
            };
            let normalized = Target {
                requested_width: active.width,
                requested_height: active.height,
                normalized_width: active.width,
                normalized_height: active.height,
            };
            let applied = result_for(
                &request,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_APPLIED,
                request.lease_id,
                Some(normalized),
                Some((active.width, active.height)),
                active.display_id,
                active.display_index,
                "this lease released; another owner keeps the display active",
            );
            self.arm_frame_confirmation(connection, request, emit, applied);
            return;
        };

        emit_result(
            &emit,
            result_for(
                &request,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_PENDING,
                plan.lease_id,
                None,
                None,
                0,
                -1,
                "release accepted",
            ),
        );
        let status = crate::platform::macos::release_owned_virtual_display(
            COORDINATOR_OWNER_TOKEN,
            plan.native_generation,
        );
        if status != crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
            self.leases.rollback_release(plan);
            self.emit_failure(
                &request,
                &emit,
                native_status_to_protocol(status),
                status,
                "native release failed; lease remains active",
            );
            return;
        }

        self.leases.commit_release(plan);
        self.active = None;
        let Some((display_id, display_index, width, height)) = self.wait_for_primary_display()
        else {
            emit_result(
                &emit,
                result_for(
                    &request,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_TIMED_OUT,
                    0,
                    None,
                    None,
                    0,
                    -1,
                    "owned resource released; fallback display enumeration timed out",
                ),
            );
            return;
        };
        let target = Target {
            requested_width: width,
            requested_height: height,
            normalized_width: width,
            normalized_height: height,
        };
        let applied = result_for(
            &request,
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_APPLIED,
            plan.lease_id,
            Some(target),
            Some((width, height)),
            display_id,
            display_index,
            "owned resource released and fallback display enumerated; waiting for frame",
        );
        self.arm_frame_confirmation(connection, request, emit, applied);
    }

    fn arm_frame_confirmation(
        &mut self,
        connection: u64,
        request: OwnedVirtualDisplayRequest,
        emit: ResultEmitter,
        applied: OwnedVirtualDisplayResult,
    ) {
        if let Some(previous) = self.waiting.remove(&connection) {
            emit_result(
                &previous.emit,
                result_with_status(
                    previous.base,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_STALE,
                    -7,
                    "confirmation superseded by a newer request",
                ),
            );
        }
        emit_result(&emit, applied.clone());
        let width = applied
            .actual
            .as_ref()
            .map(|resolution| resolution.width.max(0) as u32)
            .unwrap_or(0);
        let height = applied
            .actual
            .as_ref()
            .map(|resolution| resolution.height.max(0) as u32)
            .unwrap_or(0);
        let Some(confirmation) = (applied.display_index >= 0 && width > 0 && height > 0).then_some(
            PendingFrameConfirmation {
                request_id: request.request_id,
                generation: request.generation,
                lease_id: applied.lease_id,
                operation: match request.operation.enum_value() {
                    Ok(OwnedVirtualDisplayOperation::OWNED_DISPLAY_OPERATION_RELEASE) => 2,
                    _ => 1,
                },
                display_index: applied.display_index,
                width,
                height,
            },
        ) else {
            emit_result(
                &emit,
                result_with_status(
                    applied,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_TIMED_OUT,
                    -4,
                    "actual display observation is unavailable",
                ),
            );
            return;
        };
        self.waiting.insert(
            connection,
            WaitingForFrame {
                confirmation,
                base: applied,
                emit,
                deadline: Instant::now() + FRAME_CONFIRMATION_TIMEOUT,
            },
        );
    }

    fn handle_frame(&mut self, connection: u64, display_index: i32, width: u32, height: u32) {
        let Some(waiting) = self.waiting.get(&connection) else {
            return;
        };
        if !waiting
            .confirmation
            .matches_frame(display_index, width, height)
        {
            return;
        }
        let Some(waiting) = self.waiting.remove(&connection) else {
            return;
        };
        emit_result(
            &waiting.emit,
            result_with_status(
                waiting.base,
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_CONFIRMED,
                0,
                "matching display frame observed",
            ),
        );
    }

    fn expire_frame_waiters(&mut self) {
        let now = Instant::now();
        let expired = self
            .waiting
            .iter()
            .filter_map(|(connection, waiting)| (waiting.deadline <= now).then_some(*connection))
            .collect::<Vec<_>>();
        for connection in expired {
            if let Some(waiting) = self.waiting.remove(&connection) {
                let mut remaining_lease_id = waiting.base.lease_id;
                if waiting.confirmation.operation == 1 {
                    match self.leases.plan_disconnect(connection) {
                        Ok(Some(plan)) => {
                            let status = crate::platform::macos::release_owned_virtual_display(
                                COORDINATOR_OWNER_TOKEN,
                                plan.native_generation,
                            );
                            if status == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
                                self.leases.commit_disconnect(plan);
                                self.active = None;
                                let _ = self.wait_for_primary_display();
                                remaining_lease_id = 0;
                            } else {
                                self.leases.rollback_disconnect(plan);
                                log::error!(
                                    "Owned display timed-out lease cleanup failed conn={} status={}",
                                    connection,
                                    status
                                );
                            }
                        }
                        Ok(None) => {
                            remaining_lease_id = 0;
                        }
                        Err(error) => {
                            log::error!(
                                "Owned display timed-out lease cleanup could not be planned conn={} error={:?}",
                                connection,
                                error
                            );
                        }
                    }
                } else if self.leases.lease_id(connection).is_none() {
                    remaining_lease_id = 0;
                }
                let mut timed_out = result_with_status(
                    waiting.base,
                    OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_TIMED_OUT,
                    -5,
                    "no matching display frame before the confirmation deadline",
                );
                timed_out.lease_id = remaining_lease_id;
                emit_result(&waiting.emit, timed_out);
            }
        }
    }

    fn handle_disconnect(&mut self, connection: u64) {
        self.waiting.remove(&connection);
        if let Ok(Some(plan)) = self.leases.plan_disconnect(connection) {
            self.release_disconnected(plan);
        } else {
            self.disconnected.remove(&connection);
        }
    }

    fn release_disconnected(&mut self, plan: DisconnectPlan) {
        let status = crate::platform::macos::release_owned_virtual_display(
            COORDINATOR_OWNER_TOKEN,
            plan.native_generation,
        );
        if status == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
            self.leases.commit_disconnect(plan);
            self.disconnected.remove(&plan.connection);
            if self.leases.owner_count() == 0 {
                self.active = None;
                let _ = self.wait_for_primary_display();
            }
        } else {
            self.leases.rollback_disconnect(plan);
            self.disconnected.insert(plan.connection);
            self.next_cleanup_attempt = Instant::now() + CLEANUP_RETRY_INTERVAL;
            log::error!(
                "Owned display disconnect cleanup failed conn={} status={}",
                plan.connection,
                status
            );
        }
    }

    fn retry_disconnected_cleanup(&mut self) {
        if self.disconnected.is_empty() || Instant::now() < self.next_cleanup_attempt {
            return;
        }
        self.next_cleanup_attempt = Instant::now() + CLEANUP_RETRY_INTERVAL;
        let connections = self.disconnected.iter().copied().collect::<Vec<_>>();
        for connection in connections {
            match self.leases.plan_disconnect(connection) {
                Ok(Some(plan)) => self.release_disconnected(plan),
                Ok(None) => {
                    self.disconnected.remove(&connection);
                }
                Err(error) => log::error!(
                    "Owned display cleanup retry could not plan conn={} error={:?}",
                    connection,
                    error
                ),
            }
        }
    }

    fn recover_failed_apply(&mut self, plan: ApplyPlan, status: i32) {
        if status == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_RESTORE_FAILED {
            self.leases
                .clear_lease_after_native_loss(plan.connection, plan.lease_id);
            if self.leases.owner_count() == 0 {
                self.active = None;
            }
            return;
        }
        let Some(previous) = plan.previous_target() else {
            self.leases.rollback_apply(plan);
            let release_status = crate::platform::macos::release_owned_virtual_display(
                COORDINATOR_OWNER_TOKEN,
                plan.native_generation,
            );
            if release_status == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
                self.active = None;
            }
            return;
        };
        if plan.action != ApplyAction::Resize {
            self.leases.rollback_apply(plan);
            return;
        }
        let Ok(recovery_generation) = self.leases.reserve_recovery_native_generation() else {
            log::error!("Owned display recovery generation exhausted");
            return;
        };
        match crate::platform::macos::apply_owned_virtual_display(
            COORDINATOR_OWNER_TOKEN,
            recovery_generation,
            previous.0,
            previous.1,
        ) {
            Ok(native) => {
                if let Some(display_index) = self.wait_for_owned_display(
                    native.display_id,
                    native.pixel_width,
                    native.pixel_height,
                ) {
                    self.leases
                        .set_recovered_native_generation(recovery_generation);
                    self.leases.rollback_apply(plan);
                    self.active = Some(ActiveDisplay {
                        display_id: native.display_id,
                        display_index,
                        width: native.pixel_width,
                        height: native.pixel_height,
                    });
                    return;
                }
            }
            Err(recovery_status) => {
                log::error!("Owned display target recovery failed status={recovery_status}");
            }
        }
        let mut released = crate::platform::macos::release_owned_virtual_display(
            COORDINATOR_OWNER_TOKEN,
            recovery_generation,
        );
        if released == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_STALE_GENERATION {
            released = crate::platform::macos::release_owned_virtual_display(
                COORDINATOR_OWNER_TOKEN,
                plan.native_generation,
            );
        }
        if released == crate::platform::macos::OWNED_VIRTUAL_DISPLAY_OK {
            self.leases
                .clear_lease_after_native_loss(plan.connection, plan.lease_id);
            if self.leases.owner_count() == 0 {
                self.active = None;
            }
        }
    }

    fn wait_for_owned_display(&self, display_id: u32, width: u32, height: u32) -> Option<i32> {
        let deadline = Instant::now() + DISPLAY_ENUMERATION_TIMEOUT;
        while Instant::now() < deadline {
            let _ = display_service::check_displays_changed();
            if let Ok(displays) = display_service::try_get_displays() {
                if let Some(index) = displays.iter().enumerate().find_map(|(index, display)| {
                    let observed_id = display.name().parse::<u32>().ok()?;
                    (observed_id == display_id
                        && display.is_online()
                        && display.width() == width as usize
                        && display.height() == height as usize)
                        .then_some(index as i32)
                }) {
                    return Some(index);
                }
            }
            thread::sleep(DISPLAY_ENUMERATION_INTERVAL);
        }
        None
    }

    fn wait_for_primary_display(&self) -> Option<(u32, i32, u32, u32)> {
        let deadline = Instant::now() + DISPLAY_ENUMERATION_TIMEOUT;
        while Instant::now() < deadline {
            let _ = display_service::check_displays_changed();
            if let Ok(displays) = display_service::try_get_displays() {
                if !displays.is_empty() {
                    let index = display_service::get_primary_2(&displays);
                    if let Some(display) = displays.get(index) {
                        let width = u32::try_from(display.width()).ok()?;
                        let height = u32::try_from(display.height()).ok()?;
                        let display_id = display.name().parse::<u32>().unwrap_or(0);
                        if display.is_online() && width > 0 && height > 0 {
                            return Some((display_id, index as i32, width, height));
                        }
                    }
                }
            }
            thread::sleep(DISPLAY_ENUMERATION_INTERVAL);
        }
        None
    }

    fn emit_failure(
        &self,
        request: &OwnedVirtualDisplayRequest,
        emit: &ResultEmitter,
        status: OwnedVirtualDisplayStatus,
        error_code: i32,
        error_message: &str,
    ) {
        emit_result(
            emit,
            result_for(
                request,
                status,
                request.lease_id,
                None,
                None,
                0,
                -1,
                error_message,
            )
            .with_error_code(error_code),
        );
    }

    fn emit_lease_error(
        &self,
        request: &OwnedVirtualDisplayRequest,
        emit: &ResultEmitter,
        error: LeaseError,
    ) {
        let (status, error_code, message) = match error {
            LeaseError::Busy => (
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_BUSY,
                -6,
                "owned display has a conflicting owner or target",
            ),
            LeaseError::StaleLease | LeaseError::StaleRequest => (
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_STALE,
                -7,
                "stale request or lease",
            ),
            LeaseError::DuplicateRequest => (
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_STALE,
                -8,
                "duplicate request id",
            ),
            LeaseError::NativeGenerationExhausted => (
                OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_FAILED,
                -9,
                "display generation exhausted",
            ),
        };
        self.emit_failure(request, emit, status, error_code, message);
    }
}

fn emit_result(emit: &ResultEmitter, result: OwnedVirtualDisplayResult) {
    emit(result);
}

fn result_for(
    request: &OwnedVirtualDisplayRequest,
    status: OwnedVirtualDisplayStatus,
    lease_id: u64,
    normalized: Option<Target>,
    actual: Option<(u32, u32)>,
    display_id: u32,
    display_index: i32,
    message: &str,
) -> OwnedVirtualDisplayResult {
    let mut result = OwnedVirtualDisplayResult::new();
    result.request_id = request.request_id;
    result.generation = request.generation;
    result.set_operation(request.operation.value());
    result.set_status(status);
    result.lease_id = lease_id;
    result.requested = request.requested.clone();
    if let Some(target) = normalized {
        result.normalized = MessageField::some(Resolution {
            width: target.normalized_width as i32,
            height: target.normalized_height as i32,
            ..Default::default()
        });
    }
    if let Some((width, height)) = actual {
        result.actual = MessageField::some(Resolution {
            width: width as i32,
            height: height as i32,
            ..Default::default()
        });
    }
    result.display_id = display_id;
    result.display_index = display_index;
    result.error_message = message.to_owned();
    result
}

fn result_with_status(
    mut result: OwnedVirtualDisplayResult,
    status: OwnedVirtualDisplayStatus,
    error_code: i32,
    message: &str,
) -> OwnedVirtualDisplayResult {
    result.set_status(status);
    result.error_code = error_code;
    result.error_message = message.to_owned();
    result
}

trait ResultErrorCode {
    fn with_error_code(self, error_code: i32) -> Self;
}

impl ResultErrorCode for OwnedVirtualDisplayResult {
    fn with_error_code(mut self, error_code: i32) -> Self {
        self.error_code = error_code;
        self
    }
}

fn native_status_to_protocol(status: i32) -> OwnedVirtualDisplayStatus {
    use crate::platform::macos as platform;
    match status {
        platform::OWNED_VIRTUAL_DISPLAY_UNSAFE_TOPOLOGY
        | platform::OWNED_VIRTUAL_DISPLAY_RUNTIME_UNAVAILABLE => {
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_UNSUPPORTED
        }
        platform::OWNED_VIRTUAL_DISPLAY_BUSY_OWNER => {
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_BUSY
        }
        platform::OWNED_VIRTUAL_DISPLAY_STALE_GENERATION => {
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_STALE
        }
        platform::OWNED_VIRTUAL_DISPLAY_INVALID_ARGUMENT => {
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_INVALID_TARGET
        }
        platform::OWNED_VIRTUAL_DISPLAY_STABILITY_TIMEOUT => {
            OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_TIMED_OUT
        }
        _ => OwnedVirtualDisplayStatus::OWNED_DISPLAY_STATUS_FAILED,
    }
}

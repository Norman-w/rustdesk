//! Typed lease policy and observation rules for the macOS owned virtual display.
//!
//! This module is deliberately independent of CoreGraphics so its ownership,
//! target normalization, and request ordering rules can be tested without a
//! desktop session. The platform adapter is called by the server coordinator.

use std::collections::HashMap;

pub const OWNED_DISPLAY_MAX_WIDTH: u32 = 4096;
pub const OWNED_DISPLAY_MAX_HEIGHT: u32 = 4096;
pub const OWNED_DISPLAY_MAX_PIXELS: u64 = 8_388_608;
pub const OWNED_DISPLAY_ALIGNMENT: u32 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target {
    pub requested_width: u32,
    pub requested_height: u32,
    pub normalized_width: u32,
    pub normalized_height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TargetError {
    InvalidSize,
    InvalidCapability,
    OverLimit,
}

pub fn normalize_target(
    width: u32,
    height: u32,
    max_width: u32,
    max_height: u32,
    max_pixels: u64,
    width_alignment: u32,
    height_alignment: u32,
) -> Result<Target, TargetError> {
    if width == 0 || height == 0 {
        return Err(TargetError::InvalidSize);
    }
    if width_alignment == 0 || height_alignment == 0 {
        return Err(TargetError::InvalidCapability);
    }
    if width > max_width || height > max_height {
        return Err(TargetError::OverLimit);
    }
    let normalized_width = width - width % width_alignment;
    let normalized_height = height - height % height_alignment;
    if normalized_width == 0 || normalized_height == 0 {
        return Err(TargetError::InvalidSize);
    }
    let pixels = u64::from(normalized_width) * u64::from(normalized_height);
    if pixels > max_pixels {
        return Err(TargetError::OverLimit);
    }
    Ok(Target {
        requested_width: width,
        requested_height: height,
        normalized_width,
        normalized_height,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestOrder {
    New,
    Duplicate,
    Stale,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct LastRequest {
    request_id: u64,
    generation: u64,
}

#[derive(Default)]
pub struct RequestOrderBook {
    last: HashMap<u64, LastRequest>,
}

impl RequestOrderBook {
    pub fn observe(&mut self, connection: u64, request_id: u64, generation: u64) -> RequestOrder {
        if request_id == 0 || generation == 0 {
            return RequestOrder::Stale;
        }
        let next = LastRequest {
            request_id,
            generation,
        };
        match self.last.get(&connection) {
            Some(previous) if *previous == next => RequestOrder::Duplicate,
            Some(previous)
                if request_id <= previous.request_id || generation <= previous.generation =>
            {
                RequestOrder::Stale
            }
            _ => {
                self.last.insert(connection, next);
                RequestOrder::New
            }
        }
    }

    pub fn forget_connection(&mut self, connection: u64) {
        self.last.remove(&connection);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApplyAction {
    Create,
    Resize,
    Share,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeaseError {
    Busy,
    StaleLease,
    StaleRequest,
    DuplicateRequest,
    NativeGenerationExhausted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ApplyPlan {
    pub connection: u64,
    pub request_id: u64,
    pub generation: u64,
    pub lease_id: u64,
    pub native_generation: u64,
    pub target: Target,
    pub action: ApplyAction,
    previous_target: Option<(u32, u32)>,
}

impl ApplyPlan {
    pub fn previous_target(&self) -> Option<(u32, u32)> {
        self.previous_target
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReleasePlan {
    pub connection: u64,
    pub request_id: u64,
    pub generation: u64,
    pub lease_id: u64,
    pub native_generation: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisconnectPlan {
    pub connection: u64,
    pub lease_id: u64,
    pub native_generation: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Lease {
    id: u64,
    target: (u32, u32),
}

#[derive(Default)]
pub struct LeaseBook {
    leases: HashMap<u64, Lease>,
    next_lease_id: u64,
    next_native_generation: u64,
    active_native_generation: Option<u64>,
    requests: RequestOrderBook,
}

impl LeaseBook {
    pub fn owner_count(&self) -> usize {
        self.leases.len()
    }

    pub fn target(&self) -> Option<(u32, u32)> {
        self.leases.values().next().map(|lease| lease.target)
    }

    pub fn lease_id(&self, connection: u64) -> Option<u64> {
        self.leases.get(&connection).map(|lease| lease.id)
    }

    fn next_native_generation(&mut self) -> Result<u64, LeaseError> {
        self.next_native_generation = self
            .next_native_generation
            .checked_add(1)
            .ok_or(LeaseError::NativeGenerationExhausted)?;
        Ok(self.next_native_generation)
    }

    pub fn reserve_recovery_native_generation(&mut self) -> Result<u64, LeaseError> {
        self.next_native_generation()
    }

    pub fn set_recovered_native_generation(&mut self, generation: u64) {
        self.next_native_generation = self.next_native_generation.max(generation);
        self.active_native_generation = Some(generation);
    }

    pub fn clear_lease_after_native_loss(&mut self, connection: u64, lease_id: u64) -> bool {
        if !self
            .leases
            .get(&connection)
            .is_some_and(|lease| lease.id == lease_id)
        {
            return false;
        }
        self.leases.remove(&connection);
        if self.leases.is_empty() {
            self.active_native_generation = None;
        }
        true
    }

    fn check_order(
        &mut self,
        connection: u64,
        request_id: u64,
        generation: u64,
    ) -> Result<(), LeaseError> {
        match self.requests.observe(connection, request_id, generation) {
            RequestOrder::New => Ok(()),
            RequestOrder::Duplicate => Err(LeaseError::DuplicateRequest),
            RequestOrder::Stale => Err(LeaseError::StaleRequest),
        }
    }

    pub fn plan_apply(
        &mut self,
        connection: u64,
        request_id: u64,
        generation: u64,
        requested_lease_id: u64,
        target: Target,
    ) -> Result<ApplyPlan, LeaseError> {
        self.check_order(connection, request_id, generation)?;
        let requested_target = (target.normalized_width, target.normalized_height);
        let previous = self.leases.get(&connection).copied();
        let owner_count = self.leases.len();
        let existing_target = self.target();

        let (lease_id, action) = match previous {
            Some(lease) => {
                if requested_lease_id != lease.id {
                    return Err(LeaseError::StaleLease);
                }
                if lease.target == requested_target {
                    (lease.id, ApplyAction::Share)
                } else if owner_count == 1 {
                    (lease.id, ApplyAction::Resize)
                } else {
                    return Err(LeaseError::Busy);
                }
            }
            None => {
                if requested_lease_id != 0 {
                    return Err(LeaseError::StaleLease);
                }
                if let Some(current) = existing_target {
                    if current != requested_target {
                        return Err(LeaseError::Busy);
                    }
                    self.next_lease_id = self
                        .next_lease_id
                        .checked_add(1)
                        .ok_or(LeaseError::NativeGenerationExhausted)?;
                    (self.next_lease_id, ApplyAction::Share)
                } else {
                    self.next_lease_id = self
                        .next_lease_id
                        .checked_add(1)
                        .ok_or(LeaseError::NativeGenerationExhausted)?;
                    (self.next_lease_id, ApplyAction::Create)
                }
            }
        };

        let native_generation = if action == ApplyAction::Share {
            0
        } else {
            self.next_native_generation()?
        };
        Ok(ApplyPlan {
            connection,
            request_id,
            generation,
            lease_id,
            native_generation,
            target,
            action,
            previous_target: previous.map(|lease| lease.target),
        })
    }

    pub fn commit_apply(&mut self, plan: ApplyPlan) {
        if plan.action != ApplyAction::Share {
            self.active_native_generation = Some(plan.native_generation);
        }
        self.leases.insert(
            plan.connection,
            Lease {
                id: plan.lease_id,
                target: (plan.target.normalized_width, plan.target.normalized_height),
            },
        );
    }

    pub fn rollback_apply(&mut self, plan: ApplyPlan) {
        match plan.previous_target {
            Some(target) => {
                if let Some(lease) = self.leases.get_mut(&plan.connection) {
                    if lease.id == plan.lease_id {
                        lease.target = target;
                    }
                }
            }
            None => {
                if self
                    .leases
                    .get(&plan.connection)
                    .is_some_and(|lease| lease.id == plan.lease_id)
                {
                    self.leases.remove(&plan.connection);
                }
            }
        }
    }

    pub fn plan_release(
        &mut self,
        connection: u64,
        request_id: u64,
        generation: u64,
        requested_lease_id: u64,
    ) -> Result<Option<ReleasePlan>, LeaseError> {
        self.check_order(connection, request_id, generation)?;
        let Some(lease) = self.leases.get(&connection).copied() else {
            return if requested_lease_id == 0 {
                Ok(None)
            } else {
                Err(LeaseError::StaleLease)
            };
        };
        if lease.id != requested_lease_id {
            return Err(LeaseError::StaleLease);
        }
        if self.leases.len() > 1 {
            self.leases.remove(&connection);
            return Ok(None);
        }
        let native_generation = self
            .active_native_generation
            .ok_or(LeaseError::NativeGenerationExhausted)?;
        Ok(Some(ReleasePlan {
            connection,
            request_id,
            generation,
            lease_id: lease.id,
            native_generation,
        }))
    }

    pub fn commit_release(&mut self, plan: ReleasePlan) {
        if self.active_native_generation == Some(plan.native_generation)
            && self
                .leases
                .get(&plan.connection)
                .is_some_and(|lease| lease.id == plan.lease_id)
        {
            self.leases.remove(&plan.connection);
            self.active_native_generation = None;
        }
    }

    pub fn rollback_release(&mut self, _plan: ReleasePlan) {
        // A failed last-owner release leaves the lease active, so the helper
        // remains reachable through the same server-generated lease id.
    }

    pub fn plan_disconnect(
        &mut self,
        connection: u64,
    ) -> Result<Option<DisconnectPlan>, LeaseError> {
        self.requests.forget_connection(connection);
        let Some(lease) = self.leases.get(&connection).copied() else {
            return Ok(None);
        };
        if self.leases.len() > 1 {
            self.leases.remove(&connection);
            return Ok(None);
        }
        let native_generation = self
            .active_native_generation
            .ok_or(LeaseError::NativeGenerationExhausted)?;
        Ok(Some(DisconnectPlan {
            connection,
            lease_id: lease.id,
            native_generation,
        }))
    }

    pub fn commit_disconnect(&mut self, plan: DisconnectPlan) {
        if self.active_native_generation == Some(plan.native_generation)
            && self
                .leases
                .get(&plan.connection)
                .is_some_and(|lease| lease.id == plan.lease_id)
        {
            self.leases.remove(&plan.connection);
            self.active_native_generation = None;
        }
    }

    pub fn rollback_disconnect(&mut self, _plan: DisconnectPlan) {
        // A failed native release leaves the lease addressable for retry.
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PendingFrameConfirmation {
    pub request_id: u64,
    pub generation: u64,
    pub lease_id: u64,
    pub operation: u8,
    pub display_id: u32,
    pub display_index: i32,
    pub width: u32,
    pub height: u32,
}

impl PendingFrameConfirmation {
    pub fn matches_frame(
        &self,
        display_id: u32,
        display_index: i32,
        width: u32,
        height: u32,
    ) -> bool {
        display_id == self.display_id
            && display_index == self.display_index
            && width == self.width
            && height == self.height
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(width: u32, height: u32) -> Target {
        normalize_target(
            width,
            height,
            OWNED_DISPLAY_MAX_WIDTH,
            OWNED_DISPLAY_MAX_HEIGHT,
            OWNED_DISPLAY_MAX_PIXELS,
            OWNED_DISPLAY_ALIGNMENT,
            OWNED_DISPLAY_ALIGNMENT,
        )
        .unwrap()
    }

    #[test]
    fn odd_pixel_target_is_reported_as_requested_and_normalized() {
        assert_eq!(
            target(1235, 987),
            Target {
                requested_width: 1235,
                requested_height: 987,
                normalized_width: 1234,
                normalized_height: 986,
            }
        );
    }

    #[test]
    fn target_limits_and_alignment_are_checked_before_native_work() {
        assert_eq!(
            normalize_target(1, 200, 4096, 4096, 8_388_608, 2, 2),
            Err(TargetError::InvalidSize)
        );
        assert_eq!(
            normalize_target(4098, 100, 4096, 4096, 8_388_608, 2, 2),
            Err(TargetError::OverLimit)
        );
        assert_eq!(
            normalize_target(4096, 4096, 4096, 4096, 8_388_608, 2, 2),
            Err(TargetError::OverLimit)
        );
    }

    #[test]
    fn request_sequence_distinguishes_duplicate_and_stale() {
        let mut order = RequestOrderBook::default();
        assert_eq!(order.observe(7, 1, 1), RequestOrder::New);
        assert_eq!(order.observe(7, 1, 1), RequestOrder::Duplicate);
        assert_eq!(order.observe(7, 2, 1), RequestOrder::Stale);
        assert_eq!(order.observe(7, 2, 2), RequestOrder::New);
        assert_eq!(order.observe(8, 1, 1), RequestOrder::New);
    }

    #[test]
    fn same_target_leases_share_and_only_last_release_calls_native() {
        let requested = target(1600, 900);
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, requested).unwrap();
        assert_eq!(first.action, ApplyAction::Create);
        assert_eq!(first.native_generation, 1);
        book.commit_apply(first);

        let second = book.plan_apply(11, 1, 1, 0, requested).unwrap();
        assert_eq!(second.action, ApplyAction::Share);
        assert_eq!(second.native_generation, 0);
        book.commit_apply(second);
        assert_eq!(book.owner_count(), 2);

        assert_eq!(book.plan_release(10, 2, 2, first.lease_id).unwrap(), None);
        assert_eq!(book.owner_count(), 1);
        let last = book
            .plan_release(11, 2, 2, second.lease_id)
            .unwrap()
            .unwrap();
        assert_eq!(last.native_generation, first.native_generation);
        book.commit_release(last);
        assert_eq!(book.owner_count(), 0);
        assert_eq!(book.target(), None);
    }

    #[test]
    fn conflicting_owner_and_stale_release_cannot_change_current_lease() {
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(first);
        assert_eq!(
            book.plan_apply(11, 1, 1, 0, target(900, 1600)),
            Err(LeaseError::Busy)
        );
        assert_eq!(
            book.plan_release(10, 2, 2, first.lease_id + 1),
            Err(LeaseError::StaleLease)
        );
        assert_eq!(book.owner_count(), 1);
        assert_eq!(book.lease_id(10), Some(first.lease_id));
    }

    #[test]
    fn only_single_owner_can_resize_and_failed_resize_keeps_old_target() {
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(first);
        let resize = book
            .plan_apply(10, 2, 2, first.lease_id, target(900, 1600))
            .unwrap();
        assert_eq!(resize.action, ApplyAction::Resize);
        assert_eq!(resize.native_generation, 2);
        book.rollback_apply(resize);
        assert_eq!(book.target(), Some((1600, 900)));

        let second = book.plan_apply(11, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(second);
        assert_eq!(
            book.plan_apply(10, 3, 3, first.lease_id, target(900, 1600)),
            Err(LeaseError::Busy)
        );
    }

    #[test]
    fn stale_generation_release_cannot_delete_a_newer_lease() {
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(first);
        assert_eq!(
            book.plan_release(10, 2, 1, first.lease_id),
            Err(LeaseError::StaleRequest)
        );
        assert_eq!(book.lease_id(10), Some(first.lease_id));
        assert_eq!(book.owner_count(), 1);
    }

    #[test]
    fn disconnect_releases_only_after_last_owner_and_is_retryable() {
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(first);
        let second = book.plan_apply(11, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(second);

        assert_eq!(book.plan_disconnect(10).unwrap(), None);
        assert_eq!(book.owner_count(), 1);
        let last = book.plan_disconnect(11).unwrap().unwrap();
        assert_eq!(last.lease_id, second.lease_id);
        book.rollback_disconnect(last);
        assert_eq!(book.owner_count(), 1);
        let retry = book.plan_disconnect(11).unwrap().unwrap();
        assert_eq!(retry.native_generation, last.native_generation);
        book.commit_disconnect(retry);
        assert_eq!(book.owner_count(), 0);
    }

    #[test]
    fn delayed_release_plan_cannot_remove_a_resized_current_lease() {
        let mut book = LeaseBook::default();
        let first = book.plan_apply(10, 1, 1, 0, target(1600, 900)).unwrap();
        book.commit_apply(first);
        let delayed_release = book
            .plan_release(10, 2, 2, first.lease_id)
            .unwrap()
            .unwrap();
        assert_eq!(delayed_release.native_generation, first.native_generation);

        let resize = book
            .plan_apply(10, 3, 3, first.lease_id, target(900, 1600))
            .unwrap();
        book.commit_apply(resize);
        book.commit_release(delayed_release);
        assert_eq!(book.owner_count(), 1);
        assert_eq!(book.lease_id(10), Some(first.lease_id));
        assert_eq!(book.target(), Some((900, 1600)));
    }

    #[test]
    fn confirmation_requires_the_requested_display_and_exact_actual_frame_size() {
        let pending = PendingFrameConfirmation {
            request_id: 9,
            generation: 3,
            lease_id: 22,
            operation: 1,
            display_id: 42,
            display_index: 2,
            width: 1234,
            height: 986,
        };
        assert!(!pending.matches_frame(42, 1, 1234, 986));
        assert!(!pending.matches_frame(42, 2, 1234, 987));
        assert!(!pending.matches_frame(41, 2, 1234, 986));
        assert!(pending.matches_frame(42, 2, 1234, 986));
    }
}

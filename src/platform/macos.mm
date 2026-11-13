#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <vector>
#include <map>
#include <set>
#include <mutex>
#include <string>
#include <atomic>
#include <chrono>
#include <thread>
#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <utility>

// Private CoreGraphics runtime interfaces used for an explicitly requested,
// session-owned headless display. Keep these declarations local to this file.
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber API_AVAILABLE(macos(11.0));
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(retain, nonatomic) id queue;
@property(copy, nonatomic) id terminationHandler;
- (instancetype)init;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation API_AVAILABLE(macos(11.0));
- (instancetype)init;
@end

namespace {
std::mutex g_remote_mic_route_mutex;
AudioDeviceID g_saved_remote_mic_input = kAudioObjectUnknown;
unsigned int g_remote_mic_route_users = 0;

AudioObjectPropertyAddress remote_mic_property_address(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element) {
    AudioObjectPropertyAddress address = {selector, scope, element};
    return address;
}

AudioDeviceID find_remote_mic_input(const char *requested_name) {
    if (requested_name == nullptr || requested_name[0] == '\0') {
        return kAudioObjectUnknown;
    }

    CFStringRef requested = CFStringCreateWithCString(
        kCFAllocatorDefault, requested_name, kCFStringEncodingUTF8);
    if (requested == nullptr) {
        return kAudioObjectUnknown;
    }

    const auto devices_address = remote_mic_property_address(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &devices_address, 0, nullptr, &data_size);
    if (status != noErr || data_size < sizeof(AudioDeviceID)) {
        CFRelease(requested);
        return kAudioObjectUnknown;
    }

    std::vector<AudioDeviceID> devices(data_size / sizeof(AudioDeviceID));
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        nullptr,
        &data_size,
        devices.data());
    if (status != noErr) {
        CFRelease(requested);
        return kAudioObjectUnknown;
    }

    const auto name_address = remote_mic_property_address(
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    const auto input_stream_address = remote_mic_property_address(
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain);

    AudioDeviceID result = kAudioObjectUnknown;
    for (AudioDeviceID device : devices) {
        UInt32 name_size = sizeof(CFStringRef);
        CFStringRef device_name = nullptr;
        if (AudioObjectGetPropertyData(
                device, &name_address, 0, nullptr, &name_size, &device_name) != noErr ||
            device_name == nullptr ||
            CFStringCompare(device_name, requested, 0) != kCFCompareEqualTo) {
            continue;
        }

        UInt32 stream_size = 0;
        if (AudioObjectGetPropertyDataSize(
                device, &input_stream_address, 0, nullptr, &stream_size) != noErr ||
            stream_size < sizeof(AudioBufferList)) {
            continue;
        }

        std::vector<UInt32> storage(
            (stream_size + sizeof(UInt32) - 1) / sizeof(UInt32));
        auto *buffers = reinterpret_cast<AudioBufferList *>(storage.data());
        if (AudioObjectGetPropertyData(
                device,
                &input_stream_address,
                0,
                nullptr,
                &stream_size,
                buffers) != noErr) {
            continue;
        }

        bool has_input = false;
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
            if (buffers->mBuffers[i].mNumberChannels > 0) {
                has_input = true;
                break;
            }
        }
        if (has_input) {
            result = device;
            break;
        }
    }

    CFRelease(requested);
    return result;
}

bool get_default_remote_mic_input(AudioDeviceID *device) {
    if (device == nullptr) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(*device);
    return AudioObjectGetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, &data_size, device) == noErr &&
        *device != kAudioObjectUnknown;
}

bool set_default_remote_mic_input(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(device);
    return AudioObjectSetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, data_size, &device) == noErr;
}

AudioDeviceID find_remote_audio_output(const char *requested_name) {
    if (requested_name == nullptr || requested_name[0] == '\0') {
        return kAudioObjectUnknown;
    }

    CFStringRef requested = CFStringCreateWithCString(
        kCFAllocatorDefault, requested_name, kCFStringEncodingUTF8);
    if (requested == nullptr) {
        return kAudioObjectUnknown;
    }

    const auto devices_address = remote_mic_property_address(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &devices_address, 0, nullptr, &data_size);
    if (status != noErr || data_size < sizeof(AudioDeviceID)) {
        CFRelease(requested);
        return kAudioObjectUnknown;
    }

    std::vector<AudioDeviceID> devices(data_size / sizeof(AudioDeviceID));
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        nullptr,
        &data_size,
        devices.data());
    if (status != noErr) {
        CFRelease(requested);
        return kAudioObjectUnknown;
    }

    const auto name_address = remote_mic_property_address(
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    const auto output_stream_address = remote_mic_property_address(
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain);

    AudioDeviceID result = kAudioObjectUnknown;
    for (AudioDeviceID device : devices) {
        UInt32 name_size = sizeof(CFStringRef);
        CFStringRef device_name = nullptr;
        if (AudioObjectGetPropertyData(
                device, &name_address, 0, nullptr, &name_size, &device_name) != noErr ||
            device_name == nullptr ||
            CFStringCompare(device_name, requested, 0) != kCFCompareEqualTo) {
            continue;
        }

        UInt32 stream_size = 0;
        if (AudioObjectGetPropertyDataSize(
                device, &output_stream_address, 0, nullptr, &stream_size) != noErr ||
            stream_size < sizeof(AudioBufferList)) {
            continue;
        }

        std::vector<UInt32> storage(
            (stream_size + sizeof(UInt32) - 1) / sizeof(UInt32));
        auto *buffers = reinterpret_cast<AudioBufferList *>(storage.data());
        if (AudioObjectGetPropertyData(
                device,
                &output_stream_address,
                0,
                nullptr,
                &stream_size,
                buffers) != noErr) {
            continue;
        }

        bool has_output = false;
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
            if (buffers->mBuffers[i].mNumberChannels > 0) {
                has_output = true;
                break;
            }
        }
        if (has_output) {
            result = device;
            break;
        }
    }

    CFRelease(requested);
    return result;
}

bool get_default_remote_audio_output(AudioDeviceID *device) {
    if (device == nullptr) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(*device);
    return AudioObjectGetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, &data_size, device) == noErr &&
        *device != kAudioObjectUnknown;
}

bool set_default_remote_audio_output(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(device);
    return AudioObjectSetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, data_size, &device) == noErr;
}

bool get_default_remote_system_output(AudioDeviceID *device) {
    if (device == nullptr) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(*device);
    return AudioObjectGetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, &data_size, device) == noErr &&
        *device != kAudioObjectUnknown;
}

bool set_default_remote_system_output(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) {
        return false;
    }
    const auto address = remote_mic_property_address(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 data_size = sizeof(device);
    return AudioObjectSetPropertyData(
               kAudioObjectSystemObject, &address, 0, nullptr, data_size, &device) == noErr;
}
}  // namespace

extern "C" bool MacBeginRemoteMicRoute(const char *requested_name) {
    std::lock_guard<std::mutex> lock(g_remote_mic_route_mutex);
    if (g_remote_mic_route_users > 0) {
        ++g_remote_mic_route_users;
        return true;
    }

    AudioDeviceID target = find_remote_mic_input(requested_name);
    if (target == kAudioObjectUnknown) {
        NSLog(@"Norman remote microphone input device is unavailable");
        return false;
    }

    AudioDeviceID current = kAudioObjectUnknown;
    if (!get_default_remote_mic_input(&current)) {
        NSLog(@"Unable to read the current macOS default input device");
        return false;
    }

    if (target != current && !set_default_remote_mic_input(target)) {
        NSLog(@"Unable to set the macOS default input to the Norman virtual device");
        return false;
    }

    g_saved_remote_mic_input = current;
    g_remote_mic_route_users = 1;
    NSLog(@"Norman remote microphone input route enabled");
    return true;
}

extern "C" void MacEndRemoteMicRoute() {
    std::lock_guard<std::mutex> lock(g_remote_mic_route_mutex);
    if (g_remote_mic_route_users == 0) {
        return;
    }

    --g_remote_mic_route_users;
    if (g_remote_mic_route_users > 0) {
        return;
    }

    if (g_saved_remote_mic_input != kAudioObjectUnknown &&
        !set_default_remote_mic_input(g_saved_remote_mic_input)) {
        NSLog(@"Unable to restore the previous macOS default input device");
    } else {
        NSLog(@"Norman remote microphone input route restored");
    }
    g_saved_remote_mic_input = kAudioObjectUnknown;
}

namespace {
std::mutex g_remote_audio_route_mutex;
AudioDeviceID g_saved_remote_audio_output = kAudioObjectUnknown;
AudioDeviceID g_saved_remote_system_output = kAudioObjectUnknown;
unsigned int g_remote_audio_route_users = 0;
}  // namespace

extern "C" bool MacBeginRemoteAudioRoute(const char *requested_name) {
    std::lock_guard<std::mutex> lock(g_remote_audio_route_mutex);
    if (g_remote_audio_route_users > 0) {
        ++g_remote_audio_route_users;
        return true;
    }

    AudioDeviceID target = find_remote_audio_output(requested_name);
    if (target == kAudioObjectUnknown) {
        NSLog(@"Norman Remote Audio output device is unavailable");
        return false;
    }

    AudioDeviceID current_output = kAudioObjectUnknown;
    AudioDeviceID current_system_output = kAudioObjectUnknown;
    if (!get_default_remote_audio_output(&current_output) ||
        !get_default_remote_system_output(&current_system_output)) {
        NSLog(@"Unable to read the current macOS default output devices");
        return false;
    }

    if (target != current_output && !set_default_remote_audio_output(target)) {
        NSLog(@"Unable to set the macOS default output to Norman Remote Audio");
        return false;
    }
    if (target != current_system_output && !set_default_remote_system_output(target)) {
        if (target != current_output) {
            set_default_remote_audio_output(current_output);
        }
        NSLog(@"Unable to set the macOS system output to Norman Remote Audio");
        return false;
    }

    g_saved_remote_audio_output = current_output;
    g_saved_remote_system_output = current_system_output;
    g_remote_audio_route_users = 1;
    NSLog(@"Norman Remote Audio output route enabled");
    return true;
}

extern "C" void MacEndRemoteAudioRoute() {
    std::lock_guard<std::mutex> lock(g_remote_audio_route_mutex);
    if (g_remote_audio_route_users == 0) {
        return;
    }

    --g_remote_audio_route_users;
    if (g_remote_audio_route_users > 0) {
        return;
    }

    if (g_saved_remote_audio_output != kAudioObjectUnknown) {
        set_default_remote_audio_output(g_saved_remote_audio_output);
    }
    if (g_saved_remote_system_output != kAudioObjectUnknown) {
        set_default_remote_system_output(g_saved_remote_system_output);
    }
    NSLog(@"Norman Remote Audio output route restored");
    g_saved_remote_audio_output = kAudioObjectUnknown;
    g_saved_remote_system_output = kAudioObjectUnknown;
}

extern "C" bool CanUseNewApiForScreenCaptureCheck() {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion >= 11;
    #endif
}

extern "C" uint32_t majorVersion() {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion;
}

extern "C" bool IsCanScreenRecording(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    bool res = CGPreflightScreenCaptureAccess();
    if (!res && prompt) {
        CGRequestScreenCaptureAccess();
    }
    return res;
    #endif
}


// https://github.com/codebytere/node-mac-permissions/blob/main/permissions.mm

extern "C" bool InputMonitoringAuthStatus(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return true;
    #else
    if (floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_15) {
        IOHIDAccessType theType = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
        NSLog(@"IOHIDCheckAccess = %d, kIOHIDAccessTypeGranted = %d", theType, kIOHIDAccessTypeGranted);
        switch (theType) {
            case kIOHIDAccessTypeGranted:
                return true;
                break;
            case kIOHIDAccessTypeDenied: {
                if (prompt) {
                    NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent";
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
                }
                break;
            }
            case kIOHIDAccessTypeUnknown: {
                if (prompt) {
                    bool result = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
                    NSLog(@"IOHIDRequestAccess result = %d", result);
                }
                break;
            }
            default:
                break;
        }
    } else {
        return true;
    }
    return false;
    #endif
}

extern "C" bool Elevate(char* process, char** args) {
    AuthorizationRef authRef;
    OSStatus status;

    status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        printf("Failed to create AuthorizationRef\n");
        return false;
    }

    AuthorizationItem authItem = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights authRights = {1, &authItem};
    AuthorizationFlags flags = kAuthorizationFlagDefaults |
                                kAuthorizationFlagInteractionAllowed |
                                kAuthorizationFlagPreAuthorize |
                                kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(authRef, &authRights, kAuthorizationEmptyEnvironment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        printf("Failed to authorize\n");
        return false;
    }

    if (process != NULL) {
        FILE *pipe = NULL;
        status = AuthorizationExecuteWithPrivileges(authRef, process, kAuthorizationFlagDefaults, args, &pipe);
        if (status != errAuthorizationSuccess) {
            printf("Failed to run as root\n");
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return false;
        }
    }

    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    return true;
}

extern "C" bool MacCheckAdminAuthorization() {
    return Elevate(NULL, NULL);
}

// https://gist.github.com/briankc/025415e25900750f402235dbf1b74e42
extern "C" float BackingScaleFactor(uint32_t display) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSScreen *screen in screens) {
        NSDictionary *deviceDescription = [screen deviceDescription];
        NSNumber *screenNumber = [deviceDescription objectForKey:@"NSScreenNumber"];
        CGDirectDisplayID screenDisplayID = [screenNumber unsignedIntValue];
        if (screenDisplayID == display) {
            return [screen backingScaleFactor];
        }
    }
    return 1;
}

// https://github.com/jhford/screenresolution/blob/master/cg_utils.c
// https://github.com/jdoupe/screenres/blob/master/setgetscreen.m

size_t bitDepth(CGDisplayModeRef mode) {
    size_t depth = 0;
    // Deprecated, same display same bpp? 
    // https://stackoverflow.com/questions/8210824/how-to-avoid-cgdisplaymodecopypixelencoding-to-get-bpp
    // https://github.com/libsdl-org/SDL/pull/6628
	CFStringRef pixelEncoding = CGDisplayModeCopyPixelEncoding(mode);	
    // my numerical representation for kIO16BitFloatPixels and kIO32bitFloatPixels	
    // are made up and possibly non-sensical	
    if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO32BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 96;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO64BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 64;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO16BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 48;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 32;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO30BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 30;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 16;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive)) {	
        depth = 8;	
    }	
    CFRelease(pixelEncoding);	
    return depth;	
}

static bool isHiDPIMode(CGDisplayModeRef mode) {
    // Check if the mode is HiDPI by comparing pixel width to width
    // If pixel width is greater than width, it's a HiDPI mode
    return CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode);
}

CFArrayRef getAllModes(CGDirectDisplayID display) {
    // Create options dictionary to include HiDPI modes
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    // Include HiDPI modes
    CFDictionarySetValue(options, kCGDisplayShowDuplicateLowResolutionModes, kCFBooleanTrue);
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(display, options);
    CFRelease(options);
    return allModes;
}

extern "C" bool MacGetModeNum(CGDirectDisplayID display, uint32_t *numModes) {
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        return false;
    }
    *numModes = CFArrayGetCount(allModes);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetModes(CGDirectDisplayID display, uint32_t *widths, uint32_t *heights, bool *hidpis, uint32_t max, uint32_t *numModes) {
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return false;
    }
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return false;
    }
    uint32_t allModeCount = CFArrayGetCount(allModes);
    uint32_t realNum = 0;
    for (uint32_t i = 0; i < allModeCount && realNum < max; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {
            widths[realNum] = (uint32_t)CGDisplayModeGetWidth(mode);
            heights[realNum] = (uint32_t)CGDisplayModeGetHeight(mode);
            hidpis[realNum] = isHiDPIMode(mode);
            realNum++;
        }
    }
    *numModes = realNum;
    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetMode(CGDirectDisplayID display, uint32_t *width, uint32_t *height) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode == NULL) {
        return false;
    }
    *width = (uint32_t)CGDisplayModeGetWidth(mode);
    *height = (uint32_t)CGDisplayModeGetHeight(mode);
    CGDisplayModeRelease(mode);
    return true;
}

static bool setDisplayToMode(CGDirectDisplayID display, CGDisplayModeRef mode) {
    CGError rc;
    CGDisplayConfigRef config;
    rc = CGBeginDisplayConfiguration(&config);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    return true;
}

// Set the display to a specific mode based on width and height.
// Returns true if the display mode was successfully changed, false otherwise.
// If no such mode is available, it will not change the display mode.
//
// If `tryHiDPI` is true, it will try to set the display to a HiDPI mode if available.
// If no HiDPI mode is available, it will fall back to a non-HiDPI mode with the same resolution.
// If `tryHiDPI` is false, it sets the display to the first mode with the same resolution, no matter if it's HiDPI or not.
extern "C" bool MacSetMode(CGDirectDisplayID display, uint32_t width, uint32_t height, bool tryHiDPI)
{
    bool ret = false;
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return ret;
    }
    CFArrayRef allModes = getAllModes(display);

    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return ret;
    }
    int numModes = CFArrayGetCount(allModes);
    CGDisplayModeRef preferredHiDPIMode = NULL;
    CGDisplayModeRef fallbackMode = NULL;
    for (int i = 0; i < numModes; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (width == CGDisplayModeGetWidth(mode) &&
            height == CGDisplayModeGetHeight(mode) && 
            CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {

            if (isHiDPIMode(mode)) {
                preferredHiDPIMode = mode;
                break;
            } else {
                fallbackMode = mode;
                if (!tryHiDPI) {
                    break;
                }
            }
        }
    }

    if (preferredHiDPIMode) {
        ret = setDisplayToMode(display, preferredHiDPIMode);
    } else if (fallbackMode) {
        ret = setDisplayToMode(display, fallbackMode);
    }

    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return ret;
}

namespace {
constexpr uint32_t kOwnedVirtualDisplayVendorID = 0x4e52;   // "NR"
constexpr uint32_t kOwnedVirtualDisplayProductID = 0x30d1;  // RustDesk-owned display.
constexpr uint32_t kOwnedVirtualDisplayMaxDimension = 4096;
constexpr uint64_t kOwnedVirtualDisplayMaxPixels = 8388608;
constexpr uint32_t kOwnedVirtualDisplayAlignment = 2;
constexpr unsigned int kOwnedVirtualDisplayMinDimension = 320;
constexpr auto kOwnedVirtualDisplayStabilityTimeout = std::chrono::seconds(8);
constexpr auto kOwnedVirtualDisplayReleaseTimeout = std::chrono::seconds(5);

enum OwnedVirtualDisplayStatus : int32_t {
    kOwnedVirtualDisplayOk = 0,
    kOwnedVirtualDisplayInvalidArgument = 1,
    kOwnedVirtualDisplayRuntimeUnavailable = 2,
    kOwnedVirtualDisplayUnsafeTopology = 3,
    kOwnedVirtualDisplayBusyOwner = 4,
    kOwnedVirtualDisplayStaleGeneration = 5,
    kOwnedVirtualDisplayCreateFailed = 6,
    kOwnedVirtualDisplayApplyFailed = 7,
    kOwnedVirtualDisplayStabilityTimeout = 8,
    kOwnedVirtualDisplayRestoreFailed = 9,
};

struct OwnedVirtualDisplayState {
    CGVirtualDisplay *display = nil;
    CGVirtualDisplayDescriptor *descriptor = nil;
    CGVirtualDisplaySettings *settings = nil;
    uint64_t ownerToken = 0;
    uint64_t generation = 0;
    uint32_t displayID = 0;
    uint32_t serial = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    bool reconfigurationCallbackRegistered = false;
};

std::mutex g_ownedVirtualDisplayMutex;
OwnedVirtualDisplayState g_ownedVirtualDisplay;
std::atomic<uint64_t> g_ownedVirtualDisplayReconfigurationEvents{0};

void OwnedVirtualDisplayReconfigurationCallback(CGDirectDisplayID display,
                                                 CGDisplayChangeSummaryFlags flags,
                                                 void *userInfo) {
    (void)display;
    (void)userInfo;
    if (!(flags & kCGDisplayBeginConfigurationFlag)) {
        g_ownedVirtualDisplayReconfigurationEvents.fetch_add(1, std::memory_order_relaxed);
    }
}

bool OwnedVirtualDisplayRuntimeAvailable() {
    return NSClassFromString(@"CGVirtualDisplay") != Nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != Nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != Nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != Nil;
}

bool GetOnlineDisplayIDs(std::vector<CGDirectDisplayID> *ids) {
    if (ids == nullptr) return false;
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, nullptr, &count) != kCGErrorSuccess || count > 64) {
        return false;
    }
    if (count == 0) {
        ids->clear();
        return true;
    }
    ids->resize(count);
    if (CGGetOnlineDisplayList(count, ids->data(), &count) != kCGErrorSuccess || count > 64) {
        ids->clear();
        return false;
    }
    ids->resize(count);
    return true;
}

bool IsHeadlessPlaceholder(CGDirectDisplayID displayID) {
    return CGDisplayVendorNumber(displayID) == 0x756e6b6e &&
           CGDisplayModelNumber(displayID) == 0x76697274 &&
           CGDisplaySerialNumber(displayID) == 0 &&
           !CGDisplayIsBuiltin(displayID) && CGDisplayIsActive(displayID) &&
           CGDisplayIsOnline(displayID) && !CGDisplayIsInMirrorSet(displayID) &&
           CGDisplayPixelsWide(displayID) > 0 && CGDisplayPixelsHigh(displayID) > 0;
}

bool IsOwnedVirtualDisplay(CGDirectDisplayID displayID) {
    return g_ownedVirtualDisplay.display != nil &&
           CGDisplayVendorNumber(displayID) == kOwnedVirtualDisplayVendorID &&
           CGDisplayModelNumber(displayID) == kOwnedVirtualDisplayProductID &&
           CGDisplaySerialNumber(displayID) == g_ownedVirtualDisplay.serial &&
           !CGDisplayIsBuiltin(displayID) && CGDisplayIsActive(displayID) &&
           CGDisplayIsOnline(displayID) && !CGDisplayIsInMirrorSet(displayID) &&
           CGDisplayPixelsWide(displayID) > 0 && CGDisplayPixelsHigh(displayID) > 0;
}

CGDirectDisplayID FindOwnedVirtualDisplayID() {
    std::vector<CGDirectDisplayID> ids;
    if (!GetOnlineDisplayIDs(&ids)) return 0;
    CGDirectDisplayID found = 0;
    for (CGDirectDisplayID displayID : ids) {
        if (!IsOwnedVirtualDisplay(displayID)) continue;
        if (found != 0) return 0;
        found = displayID;
    }
    return found;
}

bool OwnedVirtualDisplayTopologyIsSafe(bool requireOwnedDisplay) {
    std::vector<CGDirectDisplayID> ids;
    if (!GetOnlineDisplayIDs(&ids)) return false;
    if (g_ownedVirtualDisplay.display == nil) {
        return ids.size() == 1 && IsHeadlessPlaceholder(ids.front()) &&
               CGMainDisplayID() == ids.front();
    }

    size_t ownedCount = 0;
    size_t placeholderCount = 0;
    for (CGDirectDisplayID displayID : ids) {
        if (IsOwnedVirtualDisplay(displayID)) {
            ++ownedCount;
        } else if (IsHeadlessPlaceholder(displayID)) {
            ++placeholderCount;
        } else {
            return false;
        }
    }
    if (ownedCount > 1 || placeholderCount > 1) return false;
    return !requireOwnedDisplay || ownedCount == 1;
}

CGVirtualDisplaySettings *CreateOwnedVirtualDisplaySettings(uint32_t width, uint32_t height) {
    CGVirtualDisplaySettings *settings = nil;
    CGVirtualDisplayMode *mode = nil;
    NSArray *modes = nil;
    @try {
        settings = [[CGVirtualDisplaySettings alloc] init];
        if (settings == nil) return nil;
        mode = [[CGVirtualDisplayMode alloc]
            initWithWidth:width height:height refreshRate:60.0];
        if (mode == nil) {
            [settings release];
            return nil;
        }
        modes = [[NSArray alloc] initWithObjects:mode, nil];
        settings.modes = modes;
        settings.hiDPI = 0;
        if (@available(macOS 11.0, *)) settings.rotation = 0;
        [modes release];
        modes = nil;
        [mode release];
        mode = nil;
        return settings;
    } @catch (NSException *exception) {
        NSLog(@"Owned virtual display mode init exception: %@", exception.reason ?: @"unknown");
        if (modes != nil) [modes release];
        if (mode != nil) [mode release];
        if (settings != nil) [settings release];
        return nil;
    }
}

CGVirtualDisplay *CreateOwnedVirtualDisplay(CGVirtualDisplayDescriptor **descriptorOut,
                                            uint32_t width,
                                            uint32_t height,
                                            uint32_t *serialOut) {
    if (descriptorOut == nullptr || serialOut == nullptr) return nil;
    *descriptorOut = nil;
    *serialOut = 0;

    uint32_t serial = arc4random();
    if (serial == 0) serial = 1;
    NSString *displayName = [NSString stringWithFormat:@"NormanRemoteDesktop-%@", NSUUID.UUID.UUIDString];
    CGVirtualDisplayDescriptor *descriptor = nil;
    CGVirtualDisplay *display = nil;
    @try {
        descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        if (descriptor == nil) return nil;
        descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        descriptor.name = displayName;
        descriptor.vendorID = kOwnedVirtualDisplayVendorID;
        descriptor.productID = kOwnedVirtualDisplayProductID;
        descriptor.serialNum = serial;
        if (@available(macOS 11.0, *)) descriptor.serialNumber = serial;
        descriptor.maxPixelsWide = kOwnedVirtualDisplayMaxDimension;
        descriptor.maxPixelsHigh = kOwnedVirtualDisplayMaxDimension;
        descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / 96.0,
                                                   25.4 * height / 96.0);
        descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
        descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
        descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
        descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
        descriptor.terminationHandler = nil;
        display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    } @catch (NSException *exception) {
        NSLog(@"Owned virtual display create exception: %@", exception.reason ?: @"unknown");
    }
    if (display == nil) {
        if (descriptor != nil) [descriptor release];
        return nil;
    }
    *descriptorOut = descriptor;
    *serialOut = serial;
    return display;
}

bool IsValidOwnedVirtualDisplaySize(uint32_t width, uint32_t height) {
    return width >= kOwnedVirtualDisplayMinDimension && height >= kOwnedVirtualDisplayMinDimension &&
           width <= kOwnedVirtualDisplayMaxDimension && height <= kOwnedVirtualDisplayMaxDimension &&
           width % kOwnedVirtualDisplayAlignment == 0 && height % kOwnedVirtualDisplayAlignment == 0 &&
           static_cast<uint64_t>(width) * static_cast<uint64_t>(height) <= kOwnedVirtualDisplayMaxPixels;
}

void ClearOwnedVirtualDisplayState() {
    if (g_ownedVirtualDisplay.reconfigurationCallbackRegistered) {
        CGDisplayRemoveReconfigurationCallback(OwnedVirtualDisplayReconfigurationCallback, nullptr);
    }
    CGVirtualDisplay *display = g_ownedVirtualDisplay.display;
    CGVirtualDisplayDescriptor *descriptor = g_ownedVirtualDisplay.descriptor;
    CGVirtualDisplaySettings *settings = g_ownedVirtualDisplay.settings;
    g_ownedVirtualDisplay = OwnedVirtualDisplayState{};
    if (display != nil) [display release];
    if (settings != nil) [settings release];
    if (descriptor != nil) [descriptor release];
}

bool WaitForOwnedVirtualDisplayRaster(uint32_t width,
                                      uint32_t height,
                                      CGDirectDisplayID *displayIDOut,
                                      uint32_t *pixelWidthOut,
                                      uint32_t *pixelHeightOut,
                                      int32_t *failureStatusOut) {
    auto deadline = std::chrono::steady_clock::now() + kOwnedVirtualDisplayStabilityTimeout;
    CGDirectDisplayID previousID = 0;
    uint32_t previousWidth = 0;
    uint32_t previousHeight = 0;
    size_t stableSamples = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        if (!OwnedVirtualDisplayTopologyIsSafe(false)) {
            if (failureStatusOut != nullptr) *failureStatusOut = kOwnedVirtualDisplayUnsafeTopology;
            return false;
        }
        CGDirectDisplayID displayID = FindOwnedVirtualDisplayID();
        if (displayID != 0) {
            uint32_t pixelWidth = static_cast<uint32_t>(CGDisplayPixelsWide(displayID));
            uint32_t pixelHeight = static_cast<uint32_t>(CGDisplayPixelsHigh(displayID));
            CGRect bounds = CGDisplayBounds(displayID);
            bool targetMatches = pixelWidth == width && pixelHeight == height &&
                std::fabs(bounds.size.width - static_cast<double>(width)) < 0.5 &&
                std::fabs(bounds.size.height - static_cast<double>(height)) < 0.5;
            if (targetMatches && displayID == previousID &&
                pixelWidth == previousWidth && pixelHeight == previousHeight) {
                ++stableSamples;
            } else {
                stableSamples = targetMatches ? 1 : 0;
            }
            previousID = displayID;
            previousWidth = pixelWidth;
            previousHeight = pixelHeight;
            if (stableSamples >= 3) {
                if (displayIDOut != nullptr) *displayIDOut = displayID;
                if (pixelWidthOut != nullptr) *pixelWidthOut = pixelWidth;
                if (pixelHeightOut != nullptr) *pixelHeightOut = pixelHeight;
                return true;
            }
        } else {
            previousID = 0;
            previousWidth = 0;
            previousHeight = 0;
            stableSamples = 0;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (failureStatusOut != nullptr) *failureStatusOut = kOwnedVirtualDisplayStabilityTimeout;
    return false;
}

bool WaitForOwnedVirtualDisplayRemoval(uint32_t serial) {
    auto deadline = std::chrono::steady_clock::now() + kOwnedVirtualDisplayReleaseTimeout;
    while (std::chrono::steady_clock::now() < deadline) {
        std::vector<CGDirectDisplayID> ids;
        if (GetOnlineDisplayIDs(&ids)) {
            bool stillOnline = false;
            for (CGDirectDisplayID displayID : ids) {
                if (CGDisplayVendorNumber(displayID) == kOwnedVirtualDisplayVendorID &&
                    CGDisplayModelNumber(displayID) == kOwnedVirtualDisplayProductID &&
                    CGDisplaySerialNumber(displayID) == serial) {
                    stillOnline = true;
                    break;
                }
            }
            if (!stillOnline) return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
}

int32_t ApplyOwnedVirtualDisplaySettings(uint32_t width,
                                         uint32_t height,
                                         CGVirtualDisplaySettings **settingsOut) {
    if (settingsOut == nullptr) return kOwnedVirtualDisplayInvalidArgument;
    *settingsOut = nil;
    CGVirtualDisplaySettings *settings = CreateOwnedVirtualDisplaySettings(width, height);
    if (settings == nil) return kOwnedVirtualDisplayApplyFailed;
    @try {
        if (![g_ownedVirtualDisplay.display applySettings:settings]) {
            [settings release];
            return kOwnedVirtualDisplayApplyFailed;
        }
        *settingsOut = settings;
        return kOwnedVirtualDisplayOk;
    } @catch (NSException *exception) {
        NSLog(@"Owned virtual display settings exception: %@", exception.reason ?: @"unknown");
        [settings release];
        return kOwnedVirtualDisplayApplyFailed;
    }
}

bool ReapplyOwnedVirtualDisplaySettings(CGVirtualDisplaySettings *settings) {
    if (settings == nil || g_ownedVirtualDisplay.display == nil) return false;
    @try {
        return [g_ownedVirtualDisplay.display applySettings:settings];
    } @catch (NSException *exception) {
        NSLog(@"Owned virtual display rollback exception: %@", exception.reason ?: @"unknown");
        return false;
    }
}
}  // namespace

// Capability probing has no display-creation or display-reconfiguration side effect.
// Status: 0 ready, 1 invalid argument, 2 runtime unavailable, 3 unsafe topology.
extern "C" int32_t MacOwnedVirtualDisplayGetCapabilities(uint32_t *maxWidth,
                                                         uint32_t *maxHeight,
                                                         uint32_t *widthAlignment,
                                                         uint32_t *heightAlignment,
                                                         uint64_t *maxPixels) {
    if (maxWidth == nullptr || maxHeight == nullptr || widthAlignment == nullptr ||
        heightAlignment == nullptr || maxPixels == nullptr) {
        return kOwnedVirtualDisplayInvalidArgument;
    }
    *maxWidth = 0;
    *maxHeight = 0;
    *widthAlignment = 0;
    *heightAlignment = 0;
    *maxPixels = 0;
    @autoreleasepool {
        std::lock_guard<std::mutex> lock(g_ownedVirtualDisplayMutex);
        if (!OwnedVirtualDisplayRuntimeAvailable()) return kOwnedVirtualDisplayRuntimeUnavailable;
        *maxWidth = kOwnedVirtualDisplayMaxDimension;
        *maxHeight = kOwnedVirtualDisplayMaxDimension;
        *widthAlignment = kOwnedVirtualDisplayAlignment;
        *heightAlignment = kOwnedVirtualDisplayAlignment;
        *maxPixels = kOwnedVirtualDisplayMaxPixels;
        if (!OwnedVirtualDisplayTopologyIsSafe(g_ownedVirtualDisplay.display != nil)) {
            return kOwnedVirtualDisplayUnsafeTopology;
        }
        return kOwnedVirtualDisplayOk;
    }
}

// Apply is synchronous but bounded to eight seconds for CG raster stabilization.
// Callers must run it on a blocking worker, never on the connection receive loop.
extern "C" int32_t MacOwnedVirtualDisplayApply(uint64_t ownerToken,
                                               uint64_t generation,
                                               uint32_t width,
                                               uint32_t height,
                                               uint32_t *displayIDOut,
                                               uint32_t *pixelWidthOut,
                                               uint32_t *pixelHeightOut) {
    if (displayIDOut == nullptr || pixelWidthOut == nullptr || pixelHeightOut == nullptr) {
        return kOwnedVirtualDisplayInvalidArgument;
    }
    *displayIDOut = 0;
    *pixelWidthOut = 0;
    *pixelHeightOut = 0;
    if (ownerToken == 0 || generation == 0 || !IsValidOwnedVirtualDisplaySize(width, height)) {
        return kOwnedVirtualDisplayInvalidArgument;
    }

    @autoreleasepool {
        std::lock_guard<std::mutex> lock(g_ownedVirtualDisplayMutex);
        if (!OwnedVirtualDisplayRuntimeAvailable()) return kOwnedVirtualDisplayRuntimeUnavailable;
        bool hadOwnedDisplay = g_ownedVirtualDisplay.display != nil;
        if (hadOwnedDisplay && ownerToken != g_ownedVirtualDisplay.ownerToken) {
            return kOwnedVirtualDisplayBusyOwner;
        }
        if (hadOwnedDisplay && generation < g_ownedVirtualDisplay.generation) {
            return kOwnedVirtualDisplayStaleGeneration;
        }
        if (!OwnedVirtualDisplayTopologyIsSafe(hadOwnedDisplay)) {
            return kOwnedVirtualDisplayUnsafeTopology;
        }
        if (hadOwnedDisplay && generation == g_ownedVirtualDisplay.generation &&
            (width != g_ownedVirtualDisplay.width || height != g_ownedVirtualDisplay.height)) {
            return kOwnedVirtualDisplayStaleGeneration;
        }

        uint32_t oldWidth = hadOwnedDisplay ? g_ownedVirtualDisplay.width : 0;
        uint32_t oldHeight = hadOwnedDisplay ? g_ownedVirtualDisplay.height : 0;
        uint64_t eventSerialAtStart = g_ownedVirtualDisplayReconfigurationEvents.load(std::memory_order_relaxed);
        if (!hadOwnedDisplay) {
            if (CGDisplayRegisterReconfigurationCallback(OwnedVirtualDisplayReconfigurationCallback,
                                                         nullptr) != kCGErrorSuccess) {
                return kOwnedVirtualDisplayApplyFailed;
            }
            g_ownedVirtualDisplay.reconfigurationCallbackRegistered = true;
            CGVirtualDisplayDescriptor *descriptor = nil;
            uint32_t serial = 0;
            CGVirtualDisplay *display = CreateOwnedVirtualDisplay(&descriptor, width, height, &serial);
            if (display == nil || descriptor == nil || serial == 0) {
                if (display != nil) [display release];
                if (descriptor != nil) [descriptor release];
                ClearOwnedVirtualDisplayState();
                return kOwnedVirtualDisplayCreateFailed;
            }
            g_ownedVirtualDisplay.display = display;
            g_ownedVirtualDisplay.descriptor = descriptor;
            g_ownedVirtualDisplay.ownerToken = ownerToken;
            g_ownedVirtualDisplay.displayID = display.displayID;
            g_ownedVirtualDisplay.serial = serial;
        }

        if (hadOwnedDisplay && generation == g_ownedVirtualDisplay.generation) {
            CGDirectDisplayID displayID = 0;
            uint32_t actualWidth = 0;
            uint32_t actualHeight = 0;
            int32_t failureStatus = kOwnedVirtualDisplayStabilityTimeout;
            if (!WaitForOwnedVirtualDisplayRaster(width, height, &displayID,
                                                   &actualWidth, &actualHeight,
                                                   &failureStatus)) {
                return failureStatus;
            }
            *displayIDOut = displayID;
            *pixelWidthOut = actualWidth;
            *pixelHeightOut = actualHeight;
            return kOwnedVirtualDisplayOk;
        }

        CGVirtualDisplaySettings *newSettings = nil;
        int32_t applyStatus = ApplyOwnedVirtualDisplaySettings(width, height, &newSettings);
        if (applyStatus != kOwnedVirtualDisplayOk) {
            if (!hadOwnedDisplay) {
                uint32_t serial = g_ownedVirtualDisplay.serial;
                ClearOwnedVirtualDisplayState();
                return WaitForOwnedVirtualDisplayRemoval(serial)
                    ? kOwnedVirtualDisplayApplyFailed : kOwnedVirtualDisplayRestoreFailed;
            }
            bool restored = oldWidth != 0 && oldHeight != 0 &&
                ReapplyOwnedVirtualDisplaySettings(g_ownedVirtualDisplay.settings);
            CGDirectDisplayID restoreID = 0;
            uint32_t restoreWidth = 0;
            uint32_t restoreHeight = 0;
            int32_t restoreFailure = kOwnedVirtualDisplayStabilityTimeout;
            restored = restored && WaitForOwnedVirtualDisplayRaster(oldWidth, oldHeight,
                &restoreID, &restoreWidth, &restoreHeight, &restoreFailure);
            if (restored) {
                g_ownedVirtualDisplay.displayID = restoreID;
                return kOwnedVirtualDisplayApplyFailed;
            }
            uint32_t serial = g_ownedVirtualDisplay.serial;
            ClearOwnedVirtualDisplayState();
            WaitForOwnedVirtualDisplayRemoval(serial);
            return kOwnedVirtualDisplayRestoreFailed;
        }

        CGDirectDisplayID actualDisplayID = 0;
        uint32_t actualWidth = 0;
        uint32_t actualHeight = 0;
        int32_t failureStatus = kOwnedVirtualDisplayStabilityTimeout;
        if (!WaitForOwnedVirtualDisplayRaster(width, height, &actualDisplayID,
                                               &actualWidth, &actualHeight,
                                               &failureStatus)) {
            if (hadOwnedDisplay) {
                bool restored = oldWidth != 0 && oldHeight != 0 &&
                    ReapplyOwnedVirtualDisplaySettings(g_ownedVirtualDisplay.settings);
                CGDirectDisplayID restoreID = 0;
                uint32_t restoreWidth = 0;
                uint32_t restoreHeight = 0;
                int32_t restoreFailure = kOwnedVirtualDisplayStabilityTimeout;
                restored = restored && WaitForOwnedVirtualDisplayRaster(oldWidth, oldHeight,
                    &restoreID, &restoreWidth, &restoreHeight, &restoreFailure);
                if (restored) {
                    if (newSettings != nil) [newSettings release];
                    g_ownedVirtualDisplay.displayID = restoreID;
                    return failureStatus;
                }
            }
            if (newSettings != nil) [newSettings release];
            uint32_t serial = g_ownedVirtualDisplay.serial;
            ClearOwnedVirtualDisplayState();
            bool removed = WaitForOwnedVirtualDisplayRemoval(serial);
            if (!removed) return kOwnedVirtualDisplayRestoreFailed;
            return failureStatus;
        }

        CGVirtualDisplaySettings *oldSettings = g_ownedVirtualDisplay.settings;
        g_ownedVirtualDisplay.settings = newSettings;
        newSettings = nil;
        if (oldSettings != nil) [oldSettings release];
        g_ownedVirtualDisplay.ownerToken = ownerToken;
        g_ownedVirtualDisplay.generation = generation;
        g_ownedVirtualDisplay.displayID = actualDisplayID;
        g_ownedVirtualDisplay.width = width;
        g_ownedVirtualDisplay.height = height;
        *displayIDOut = actualDisplayID;
        *pixelWidthOut = actualWidth;
        *pixelHeightOut = actualHeight;
        uint64_t eventsSeen = g_ownedVirtualDisplayReconfigurationEvents.load(std::memory_order_relaxed) -
                              eventSerialAtStart;
        NSLog(@"Owned virtual display applied: id=%u size=%ux%u generation=%llu reconfigurationEvents=%llu",
              actualDisplayID, actualWidth, actualHeight,
              static_cast<unsigned long long>(generation),
              static_cast<unsigned long long>(eventsSeen));
        return kOwnedVirtualDisplayOk;
    }
}

// Release is idempotent after cleanup and never changes another display's mode or topology.
extern "C" int32_t MacOwnedVirtualDisplayRelease(uint64_t ownerToken, uint64_t generation) {
    if (ownerToken == 0 || generation == 0) return kOwnedVirtualDisplayInvalidArgument;
    @autoreleasepool {
        std::lock_guard<std::mutex> lock(g_ownedVirtualDisplayMutex);
        if (g_ownedVirtualDisplay.display == nil) return kOwnedVirtualDisplayOk;
        if (ownerToken != g_ownedVirtualDisplay.ownerToken) return kOwnedVirtualDisplayBusyOwner;
        if (generation != g_ownedVirtualDisplay.generation) return kOwnedVirtualDisplayStaleGeneration;
        uint32_t serial = g_ownedVirtualDisplay.serial;
        uint32_t displayID = g_ownedVirtualDisplay.displayID;
        ClearOwnedVirtualDisplayState();
        bool removed = WaitForOwnedVirtualDisplayRemoval(serial);
        NSLog(@"Owned virtual display released: id=%u removed=%d", displayID, removed ? 1 : 0);
        return removed ? kOwnedVirtualDisplayOk : kOwnedVirtualDisplayRestoreFailed;
    }
}

static CFMachPortRef g_eventTap = NULL;
static CFRunLoopSourceRef g_runLoopSource = NULL;
static std::mutex g_privacyModeMutex;
static bool g_privacyModeActive = false;

// Flag to request asynchronous shutdown of privacy mode.
// This is set by DisplayReconfigurationCallback when an error occurs, instead of calling
// TurnOffPrivacyModeInternal() directly from within the callback. This avoids potential
// issues with unregistering a callback from within itself, which is not explicitly
// guaranteed to be safe by Apple documentation.
static bool g_privacyModeShutdownRequested = false;

// Timestamp of the last display reconfiguration event (in milliseconds).
// Used for debouncing rapid successive changes (e.g., multiple resolution changes).
static uint64_t g_lastReconfigTimestamp = 0;

// Flag indicating whether a delayed blackout reapplication is already scheduled.
// Prevents multiple concurrent delayed tasks from being created.
static bool g_blackoutReapplicationScheduled = false;

// Use CFStringRef (UUID) as key instead of CGDirectDisplayID for stability across reconnections
// CGDirectDisplayID can change when displays are reconnected, but UUID remains stable
static std::map<std::string, std::vector<CGGammaValue>> g_originalGammas;

// The event source user data value used by enigo library for injected events.
// This allows us to distinguish remote input (which should be allowed) from local physical input.
// See: libs/enigo/src/macos/macos_impl.rs - ENIGO_INPUT_EXTRA_VALUE
static const int64_t ENIGO_INPUT_EXTRA_VALUE = 100;

// Duration in milliseconds to monitor and enforce blackout after display reconfiguration.
// macOS may restore default gamma (via ColorSync) at unpredictable times after display changes,
// so we need to actively monitor and reapply blackout during this period.
static const int64_t DISPLAY_RECONFIG_MONITOR_DURATION_MS = 5000;

// Interval in milliseconds between gamma checks during the monitoring period.
static const int64_t GAMMA_CHECK_INTERVAL_MS = 200;

// Helper function to get UUID string from DisplayID
static std::string GetDisplayUUID(CGDirectDisplayID displayId) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayId);
    if (uuid == NULL) {
        return "";
    }
    CFStringRef uuidStr = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    if (uuidStr == NULL) {
        return "";
    }
    char buffer[128];
    if (CFStringGetCString(uuidStr, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        CFRelease(uuidStr);
        return std::string(buffer);
    }
    CFRelease(uuidStr);
    return "";
}

// Helper function to find DisplayID by UUID from current online displays
static CGDirectDisplayID FindDisplayIdByUUID(const std::string& targetUuid) {
    uint32_t count = 0;
    CGGetOnlineDisplayList(0, NULL, &count);
    if (count == 0) return kCGNullDirectDisplay;
    
    std::vector<CGDirectDisplayID> displays(count);
    CGGetOnlineDisplayList(count, displays.data(), &count);
    
    for (uint32_t i = 0; i < count; i++) {
        std::string uuid = GetDisplayUUID(displays[i]);
        if (uuid == targetUuid) {
            return displays[i];
        }
    }
    return kCGNullDirectDisplay;
}

// Helper function to restore gamma values for all displays in g_originalGammas.
// Returns true if all displays were restored successfully, false if any failed.
// Note: This function does NOT clear g_originalGammas - caller should do that if needed.
static bool RestoreAllGammas() {
    bool allSuccess = true;
    for (auto const& [uuid, gamma] : g_originalGammas) {
        CGDirectDisplayID d = FindDisplayIdByUUID(uuid);
        if (d == kCGNullDirectDisplay) {
            NSLog(@"Display with UUID %s no longer online, skipping gamma restore", uuid.c_str());
            continue;
        }
        
        uint32_t sampleCount = gamma.size() / 3;
        if (sampleCount > 0) {
            const CGGammaValue* red = gamma.data();
            const CGGammaValue* green = red + sampleCount;
            const CGGammaValue* blue = green + sampleCount;
            CGError error = CGSetDisplayTransferByTable(d, sampleCount, red, green, blue);
            if (error != kCGErrorSuccess) {
                NSLog(@"Failed to restore gamma for display (ID: %u, UUID: %s, error: %d)", (unsigned)d, uuid.c_str(), error);
                allSuccess = false;
            }
        }
    }
    return allSuccess;
}

// Helper function to apply blackout to a single display
static bool ApplyBlackoutToDisplay(CGDirectDisplayID display) {
    uint32_t capacity = CGDisplayGammaTableCapacity(display);
    if (capacity > 0) {
        std::vector<CGGammaValue> zeros(capacity, 0.0f);
        CGError error = CGSetDisplayTransferByTable(display, capacity, zeros.data(), zeros.data(), zeros.data());
        if (error != kCGErrorSuccess) {
            NSLog(@"ApplyBlackoutToDisplay: Failed to set gamma for display %u (error %d)", (unsigned)display, error);
            return false;
        }
        return true;
    }
    NSLog(@"ApplyBlackoutToDisplay: Display %u has zero gamma table capacity, blackout not supported", (unsigned)display);
    return false;
}

// Forward declaration - defined later in the file
// Must be called while holding g_privacyModeMutex
static bool TurnOffPrivacyModeInternal();

// Helper function to schedule asynchronous shutdown of privacy mode.
// This is called from DisplayReconfigurationCallback when an error occurs,
// instead of calling TurnOffPrivacyModeInternal() directly. This avoids
// potential issues with unregistering a callback from within itself.
// Note: This function should be called while holding g_privacyModeMutex.
static void ScheduleAsyncPrivacyModeShutdown(const char* reason) {
    if (g_privacyModeShutdownRequested) {
        // Already requested, no need to schedule again
        return;
    }
    g_privacyModeShutdownRequested = true;
    NSLog(@"Privacy mode shutdown requested: %s", reason);
    
    // Schedule the actual shutdown on the main queue asynchronously
    // This ensures we're outside the callback when we unregister it
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_privacyModeMutex);
        if (g_privacyModeShutdownRequested && g_privacyModeActive) {
            NSLog(@"Executing deferred privacy mode shutdown");
            TurnOffPrivacyModeInternal();
        }
        g_privacyModeShutdownRequested = false;
    });
}

// Helper function to apply blackout to all online displays.
// Must be called while holding g_privacyModeMutex.
static void ApplyBlackoutToAllDisplays() {
    uint32_t onlineCount = 0;
    CGGetOnlineDisplayList(0, NULL, &onlineCount);
    std::vector<CGDirectDisplayID> onlineDisplays(onlineCount);
    CGGetOnlineDisplayList(onlineCount, onlineDisplays.data(), &onlineCount);
    
    for (uint32_t i = 0; i < onlineCount; i++) {
        ApplyBlackoutToDisplay(onlineDisplays[i]);
    }
}

// Helper function to get current timestamp in milliseconds
static uint64_t GetCurrentTimestampMs() {
    return (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

// Helper function to check if a display's gamma is currently blacked out (all zeros).
// Returns true if gamma appears to be blacked out, false otherwise.
static bool IsDisplayBlackedOut(CGDirectDisplayID display) {
    uint32_t capacity = CGDisplayGammaTableCapacity(display);
    if (capacity == 0) {
        return true; // Can't check, assume it's fine
    }
    
    std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
    uint32_t sampleCount = 0;
    if (CGGetDisplayTransferByTable(display, capacity, red.data(), green.data(), blue.data(), &sampleCount) != kCGErrorSuccess) {
        return true; // Can't read, assume it's fine
    }
    
    // Check if all values are zero (or very close to zero)
    for (uint32_t i = 0; i < sampleCount; i++) {
        if (red[i] > 0.01f || green[i] > 0.01f || blue[i] > 0.01f) {
            return false; // Not blacked out
        }
    }
    return true;
}

// Internal function that monitors and enforces blackout for a period after display reconfiguration.
// This function checks gamma values periodically and reapplies blackout if needed.
// Must NOT be called while holding g_privacyModeMutex (it acquires the lock internally).
static void RunBlackoutMonitor() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GAMMA_CHECK_INTERVAL_MS * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_privacyModeMutex);
        
        if (!g_privacyModeActive) {
            g_blackoutReapplicationScheduled = false;
            return;
        }
        
        uint64_t now = GetCurrentTimestampMs();
        
        // Calculate effective end time based on the last reconfig event
        uint64_t effectiveEndTime = g_lastReconfigTimestamp + DISPLAY_RECONFIG_MONITOR_DURATION_MS;
        
        // Check all displays and reapply blackout if any has been restored
        uint32_t onlineCount = 0;
        CGGetOnlineDisplayList(0, NULL, &onlineCount);
        std::vector<CGDirectDisplayID> onlineDisplays(onlineCount);
        CGGetOnlineDisplayList(onlineCount, onlineDisplays.data(), &onlineCount);
        
        bool needsReapply = false;
        for (uint32_t i = 0; i < onlineCount; i++) {
            if (!IsDisplayBlackedOut(onlineDisplays[i])) {
                needsReapply = true;
                break;
            }
        }
        
        if (needsReapply) {
            NSLog(@"Gamma was restored by system, reapplying blackout");
            ApplyBlackoutToAllDisplays();
        }
        
        // Continue monitoring if we haven't reached the end time
        if (now < effectiveEndTime) {
            RunBlackoutMonitor();
        } else {
            NSLog(@"Blackout monitoring period ended");
            g_blackoutReapplicationScheduled = false;
        }
    });
}

// Helper function to start monitoring and enforcing blackout after display reconfiguration.
// This is used after display reconfiguration events because macOS may restore
// default gamma (via ColorSync) at unpredictable times after display changes.
// Note: This function should be called while holding g_privacyModeMutex.
static void ScheduleDelayedBlackoutReapplication(const char* reason) {
    // Update timestamp to current time
    g_lastReconfigTimestamp = GetCurrentTimestampMs();
    
    NSLog(@"Starting blackout monitor: %s", reason);
    
    // Only schedule if not already scheduled
    if (!g_blackoutReapplicationScheduled) {
        g_blackoutReapplicationScheduled = true;
        RunBlackoutMonitor();
    }
    // If already scheduled, the running monitor will see the updated timestamp
    // and extend its monitoring period
}

// Display reconfiguration callback to handle display connect/disconnect events
//
// IMPORTANT: When errors occur in this callback, we use ScheduleAsyncPrivacyModeShutdown()
// instead of calling TurnOffPrivacyModeInternal() directly. This is because:
// 1. TurnOffPrivacyModeInternal() calls CGDisplayRemoveReconfigurationCallback to unregister
//    this callback, and unregistering a callback from within itself is not explicitly
//    guaranteed to be safe by Apple documentation.
// 2. Using async dispatch ensures we're completely outside the callback context when
//    performing the cleanup, avoiding any potential undefined behavior.
static void DisplayReconfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    (void)userInfo;
    
    // Note: We need to handle the callback carefully because:
    // 1. macOS may call this callback multiple times during display reconfiguration
    // 2. The system may restore ColorSync settings after our gamma change
    // 3. We should not hold the lock for too long in the callback
    
    // Skip begin configuration flag - wait for the actual change
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    
    std::lock_guard<std::mutex> lock(g_privacyModeMutex);
    
    if (!g_privacyModeActive) {
        return;
    }
    
    if (flags & kCGDisplayAddFlag) {
        // A display was added - apply blackout to it
        NSLog(@"Display %u added during privacy mode, applying blackout", (unsigned)display);
        std::string uuid = GetDisplayUUID(display);
        if (uuid.empty()) {
            NSLog(@"Failed to get UUID for newly added display %u, exiting privacy mode", (unsigned)display);
            ScheduleAsyncPrivacyModeShutdown("Failed to get UUID for newly added display");
            return;
        }
        
        // Save original gamma if not already saved for this UUID
        if (g_originalGammas.find(uuid) == g_originalGammas.end()) {
            uint32_t capacity = CGDisplayGammaTableCapacity(display);
            if (capacity > 0) {
                std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
                uint32_t sampleCount = 0;
                if (CGGetDisplayTransferByTable(display, capacity, red.data(), green.data(), blue.data(), &sampleCount) == kCGErrorSuccess) {
                    std::vector<CGGammaValue> all;
                    all.insert(all.end(), red.begin(), red.begin() + sampleCount);
                    all.insert(all.end(), green.begin(), green.begin() + sampleCount);
                    all.insert(all.end(), blue.begin(), blue.begin() + sampleCount);
                    g_originalGammas[uuid] = all;
                } else {
                    NSLog(@"DisplayReconfigurationCallback: Failed to get gamma table for display %u (UUID: %s), exiting privacy mode", (unsigned)display, uuid.c_str());
                    ScheduleAsyncPrivacyModeShutdown("Failed to get gamma table for newly added display");
                    return;
                }
            } else {
                NSLog(@"DisplayReconfigurationCallback: Display %u (UUID: %s) has zero gamma table capacity, exiting privacy mode", (unsigned)display, uuid.c_str());
                ScheduleAsyncPrivacyModeShutdown("Newly added display has zero gamma table capacity");
                return;
            }
        }
        
        // Apply blackout to the new display immediately
        if (!ApplyBlackoutToDisplay(display)) {
            NSLog(@"DisplayReconfigurationCallback: Failed to blackout display %u (UUID: %s), exiting privacy mode", (unsigned)display, uuid.c_str());
            ScheduleAsyncPrivacyModeShutdown("Failed to blackout newly added display");
            return;
        }
        
        // Schedule a delayed re-application to handle ColorSync restoration
        // macOS may restore default gamma for ALL displays after a new display is added,
        // so we need to reapply blackout to all online displays, not just the new one
        ScheduleDelayedBlackoutReapplication("after new display added");
    } else if (flags & kCGDisplayRemoveFlag) {
        // A display was removed - update our mapping and reapply blackout to remaining displays
        NSLog(@"Display %u removed during privacy mode", (unsigned)display);
        std::string uuid = GetDisplayUUID(display);
        (void)uuid; // UUID retrieved for potential future use or logging
        
        // When a display is removed, macOS may reconfigure other displays and restore their gamma.
        // Schedule a delayed re-application of blackout to all remaining online displays.
        ScheduleDelayedBlackoutReapplication("after display removal");
    } else if (flags & kCGDisplaySetModeFlag) {
        // Display mode changed (resolution change, ColorSync/Night Shift interference, etc.)
        // macOS resets gamma to default when display mode changes, so we need to reapply blackout.
        // Schedule a delayed re-application because ColorSync restoration happens asynchronously.
        NSLog(@"Display %u mode changed during privacy mode, reapplying blackout", (unsigned)display);
        ScheduleDelayedBlackoutReapplication("after display mode change");
    }
}

CGEventRef MyEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;
    
    // Handle EventTap being disabled by system timeout
    if (type == kCGEventTapDisabledByTimeout) {
        NSLog(@"EventTap was disabled by timeout, re-enabling");
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, true);
        }
        return event;
    }
    
    // Handle EventTap being disabled by user input
    if (type == kCGEventTapDisabledByUserInput) {
        NSLog(@"EventTap was disabled by user input, re-enabling");
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, true);
        }
        return event;
    }
    
    // Allow events explicitly injected by enigo (remote input), identified via custom user data.
    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (userData == ENIGO_INPUT_EXTRA_VALUE) {
        return event;
    }
    // Block local physical HID input.
    if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState) {
        return NULL;
    }
    return event;
}

// Helper function to set up EventTap on the main thread
// Returns true if EventTap was successfully created and enabled
static bool SetupEventTapOnMainThread() {
    __block bool success = false;
    
    void (^setupBlock)(void) = ^{
        if (g_eventTap) {
            // Already set up
            success = true;
            return;
        }
        
        // Note: kCGEventTapDisabledByTimeout and kCGEventTapDisabledByUserInput are special
        // notification types (0xFFFFFFFE and 0xFFFFFFFF) that are delivered via the callback's
        // type parameter, not through the event mask. They should NOT be included in eventMask
        // as bit-shifting by these values causes undefined behavior.
        CGEventMask eventMask = (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp) |
                                (1 << kCGEventLeftMouseDown) | (1 << kCGEventLeftMouseUp) |
                                (1 << kCGEventRightMouseDown) | (1 << kCGEventRightMouseUp) |
                                (1 << kCGEventOtherMouseDown) | (1 << kCGEventOtherMouseUp) |
                                (1 << kCGEventLeftMouseDragged) | (1 << kCGEventRightMouseDragged) |
                                (1 << kCGEventOtherMouseDragged) |
                                (1 << kCGEventMouseMoved) | (1 << kCGEventScrollWheel);
        
        g_eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                      eventMask, MyEventTapCallback, NULL);
        if (g_eventTap) {
            g_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(g_eventTap, true);
            success = true;
        } else {
            NSLog(@"MacSetPrivacyMode: Failed to create CGEventTap; input blocking not enabled.");
            success = false;
        }
    };
    
    // Execute on main thread to ensure CFRunLoop operations are safe.
    // Use dispatch_sync if not on main thread, otherwise execute directly to avoid deadlock.
    //
    // IMPORTANT: Potential deadlock consideration:
    // Using dispatch_sync while holding g_privacyModeMutex could deadlock if the main thread
    // tries to acquire g_privacyModeMutex. Currently this is safe because:
    // 1. MacSetPrivacyMode (which holds the mutex) is only called from background threads
    // 2. The main thread never directly calls MacSetPrivacyMode
    // If this assumption changes in the future, consider releasing the mutex before dispatch_sync
    // or restructuring the locking strategy.
    if ([NSThread isMainThread]) {
        setupBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), setupBlock);
    }
    
    return success;
}

// Helper function to tear down EventTap on the main thread
static void TeardownEventTapOnMainThread() {
    void (^teardownBlock)(void) = ^{
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, false);
            CFRunLoopRemoveSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CFRelease(g_runLoopSource);
            CFRelease(g_eventTap);
            g_eventTap = NULL;
            g_runLoopSource = NULL;
        }
    };
    
    // Execute on main thread to ensure CFRunLoop operations are safe.
    //
    // NOTE: We use dispatch_sync here instead of dispatch_async because:
    // 1. TurnOffPrivacyModeInternal() expects EventTap to be fully torn down before
    //    proceeding with gamma restoration - using async would cause race conditions.
    // 2. The caller (MacSetPrivacyMode) needs deterministic cleanup order.
    //
    // IMPORTANT: Potential deadlock consideration (same as SetupEventTapOnMainThread):
    // Using dispatch_sync while holding g_privacyModeMutex could deadlock if the main thread
    // tries to acquire g_privacyModeMutex. Currently this is safe because:
    // 1. MacSetPrivacyMode (which holds the mutex) is only called from background threads
    // 2. The main thread never directly calls MacSetPrivacyMode
    // If this assumption changes in the future, consider releasing the mutex before dispatch_sync
    // or restructuring the locking strategy.
    if ([NSThread isMainThread]) {
        teardownBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), teardownBlock);
    }
}

// Internal function to turn off privacy mode without acquiring the mutex
// Must be called while holding g_privacyModeMutex
static bool TurnOffPrivacyModeInternal() {
    if (!g_privacyModeActive) {
        return true;
    }
    
    // 1. Unregister display reconfiguration callback
    CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
    
    // 2. Input - restore (tear down EventTap on main thread)
    TeardownEventTapOnMainThread();

    // 3. Gamma - restore using UUID to find current DisplayID
    bool restoreSuccess = RestoreAllGammas();
    
    // 4. Fallback: Always call CGDisplayRestoreColorSyncSettings as a safety net
    // This ensures displays return to normal even if our restoration failed or
    // if the system (ColorSync/Night Shift) modified gamma during privacy mode
    CGDisplayRestoreColorSyncSettings();
    
    // Clean up
    g_originalGammas.clear();
    g_privacyModeActive = false;
    g_privacyModeShutdownRequested = false;
    g_lastReconfigTimestamp = 0;
    g_blackoutReapplicationScheduled = false;
    
    return restoreSuccess;
}

extern "C" bool MacSetPrivacyMode(bool on) {
    std::lock_guard<std::mutex> lock(g_privacyModeMutex);
    if (on) {
        // Already in privacy mode
        if (g_privacyModeActive) {
            return true;
        }
        
        // 1. Input Blocking - set up EventTap on main thread
        if (!SetupEventTapOnMainThread()) {
            return false;
        }

        // 2. Register display reconfiguration callback to handle hot-plug events
        CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationCallback, NULL);

        // 3. Gamma Blackout
        uint32_t count = 0;
        CGGetOnlineDisplayList(0, NULL, &count);
        std::vector<CGDirectDisplayID> displays(count);
        CGGetOnlineDisplayList(count, displays.data(), &count);

        uint32_t blackoutSuccessCount = 0;
        uint32_t blackoutAttemptCount = 0;

        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = displays[i];
            std::string uuid = GetDisplayUUID(d);
            
            if (uuid.empty()) {
                NSLog(@"MacSetPrivacyMode: Failed to get UUID for display %u, privacy mode requires all displays", (unsigned)d);
                // Privacy mode requires ALL connected displays to be successfully blacked out 
                // to ensure user privacy. If we can't identify a display (no UUID), 
                // we can't safely manage its state or restore it later.
                // Therefore, we must abort the entire operation and clean up any resources
                // already allocated (like event taps and reconfiguration callbacks).
                CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
                TeardownEventTapOnMainThread();
                // Restore gamma for displays that were already blacked out before this failure
                if (!RestoreAllGammas()) {
                    // If any display failed to restore, use system reset as fallback
                    CGDisplayRestoreColorSyncSettings();
                }
                g_originalGammas.clear();
                return false;
            }
            
            // Save original gamma using UUID as key (stable across reconnections)
            if (g_originalGammas.find(uuid) == g_originalGammas.end()) {
                uint32_t capacity = CGDisplayGammaTableCapacity(d);
                if (capacity > 0) {
                    std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
                    uint32_t sampleCount = 0;
                    if (CGGetDisplayTransferByTable(d, capacity, red.data(), green.data(), blue.data(), &sampleCount) == kCGErrorSuccess) {
                        std::vector<CGGammaValue> all;
                        all.insert(all.end(), red.begin(), red.begin() + sampleCount);
                        all.insert(all.end(), green.begin(), green.begin() + sampleCount);
                        all.insert(all.end(), blue.begin(), blue.begin() + sampleCount);
                        g_originalGammas[uuid] = all;
                    } else {
                        NSLog(@"MacSetPrivacyMode: Failed to get gamma table for display %u (UUID: %s)", (unsigned)d, uuid.c_str());
                    }
                } else {
                    NSLog(@"MacSetPrivacyMode: Display %u (UUID: %s) has zero gamma table capacity, not supported", (unsigned)d, uuid.c_str());
                }
            }

            // Set to black only if we have saved original gamma for this display
            if (g_originalGammas.find(uuid) != g_originalGammas.end()) {
                uint32_t capacity = CGDisplayGammaTableCapacity(d);
                if (capacity > 0) {
                    std::vector<CGGammaValue> zeros(capacity, 0.0f);
                    blackoutAttemptCount++;
                    CGError error = CGSetDisplayTransferByTable(d, capacity, zeros.data(), zeros.data(), zeros.data());
                    if (error != kCGErrorSuccess) {
                        NSLog(@"MacSetPrivacyMode: Failed to blackout display (ID: %u, UUID: %s, error: %d)", (unsigned)d, uuid.c_str(), error);
                    } else {
                        blackoutSuccessCount++;
                    }
                } else {
                    NSLog(@"MacSetPrivacyMode: Display %u (UUID: %s) has zero gamma table capacity for blackout", (unsigned)d, uuid.c_str());
                }
            }
        }
        
        // Return false if any display failed to blackout - privacy mode requires ALL displays to be blacked out
        if (blackoutAttemptCount > 0 && blackoutSuccessCount < blackoutAttemptCount) {
            NSLog(@"MacSetPrivacyMode: Failed to blackout all displays (%u/%u succeeded)", blackoutSuccessCount, blackoutAttemptCount);
            // Clean up: unregister callback and disable event tap since we're failing
            CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
            TeardownEventTapOnMainThread();
            // Restore gamma for displays that were successfully blacked out
            if (!RestoreAllGammas()) {
                // If any display failed to restore, use system reset as fallback
                NSLog(@"Some displays failed to restore gamma during cleanup, using CGDisplayRestoreColorSyncSettings as fallback");
                CGDisplayRestoreColorSyncSettings();
            }
            g_originalGammas.clear();
            return false;
        }
        
        g_privacyModeActive = true;
        return true;

    } else {
        return TurnOffPrivacyModeInternal();
    }
}

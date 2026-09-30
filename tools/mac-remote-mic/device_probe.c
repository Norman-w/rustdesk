#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_cf_string(const char *label, CFStringRef value) {
    char buffer[512] = {0};
    if (value && CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s=%s", label, buffer);
    } else {
        printf("%s=", label);
    }
}

static CFStringRef copy_string_property(AudioDeviceID device, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) {
        return NULL;
    }
    return value;
}

static UInt32 channel_count(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) {
        return 0;
    }
    AudioBufferList *list = (AudioBufferList *)calloc(1, size);
    if (!list) {
        return 0;
    }
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            channels += list->mBuffers[i].mNumberChannels;
        }
    }
    free(list);
    return channels;
}

static double nominal_sample_rate(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate) != noErr) {
        return 0;
    }
    return rate;
}

enum channel_requirement {
    REQUIRE_INPUT = 1,
    REQUIRE_OUTPUT = 2,
    REQUIRE_DUPLEX = 3,
};

static int check_device(const char *requested_name, enum channel_requirement requirement) {
    if (!requested_name || requested_name[0] == '\0') {
        fprintf(stderr, "device name is required\n");
        return 64;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        fprintf(stderr, "cannot enumerate CoreAudio devices: %d\n", (int)status);
        return 2;
    }

    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devices = (AudioDeviceID *)calloc(count, sizeof(AudioDeviceID));
    if (!devices) {
        return 2;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    if (status != noErr) {
        fprintf(stderr, "cannot read CoreAudio devices: %d\n", (int)status);
        free(devices);
        return 2;
    }

    CFStringRef requested = CFStringCreateWithCString(NULL, requested_name, kCFStringEncodingUTF8);
    if (!requested) {
        free(devices);
        return 64;
    }

    int result = 3;
    for (UInt32 i = 0; i < count; i++) {
        CFStringRef name = copy_string_property(devices[i], kAudioObjectPropertyName);
        if (name && CFStringCompare(name, requested, 0) == kCFCompareEqualTo) {
            UInt32 input_channels = channel_count(devices[i], kAudioDevicePropertyScopeInput);
            UInt32 output_channels = channel_count(devices[i], kAudioDevicePropertyScopeOutput);
            printf("found=1 input_channels=%u output_channels=%u sample_rate=%.0f\n",
                   input_channels, output_channels, nominal_sample_rate(devices[i]));
            if (requirement == REQUIRE_INPUT) {
                result = input_channels > 0 ? 0 : 4;
            } else if (requirement == REQUIRE_OUTPUT) {
                result = output_channels > 0 ? 0 : 4;
            } else {
                result = input_channels > 0 && output_channels > 0 ? 0 : 4;
            }
            if (name) CFRelease(name);
            break;
        }
        if (name) CFRelease(name);
    }

    CFRelease(requested);
    if (result == 3) {
        printf("found=0 input_channels=0 output_channels=0 sample_rate=0\n");
    }
    free(devices);
    return result;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--check-input") == 0) {
        return check_device(argv[2], REQUIRE_INPUT);
    }
    if (argc == 3 && strcmp(argv[1], "--check-output") == 0) {
        return check_device(argv[2], REQUIRE_OUTPUT);
    }
    if (argc == 3 && strcmp(argv[1], "--check-duplex") == 0) {
        return check_device(argv[2], REQUIRE_DUPLEX);
    }
    if (argc != 1) {
        fprintf(stderr, "usage: %s [--check-input DEVICE_NAME | --check-output DEVICE_NAME | --check-duplex DEVICE_NAME]\n", argv[0]);
        return 64;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        fprintf(stderr, "cannot enumerate CoreAudio devices: %d\n", (int)status);
        return 2;
    }

    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devices = (AudioDeviceID *)calloc(count, sizeof(AudioDeviceID));
    if (!devices) {
        return 2;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    if (status != noErr) {
        fprintf(stderr, "cannot read CoreAudio devices: %d\n", (int)status);
        free(devices);
        return 2;
    }

    printf("coreaudio_devices=%u\n", count);
    for (UInt32 i = 0; i < count; i++) {
        CFStringRef name = copy_string_property(devices[i], kAudioObjectPropertyName);
        CFStringRef uid = copy_string_property(devices[i], kAudioDevicePropertyDeviceUID);
        CFStringRef manufacturer = copy_string_property(devices[i], kAudioObjectPropertyManufacturer);
        printf("device[%u].id=%u ", i, devices[i]);
        print_cf_string("name", name);
        printf(" ");
        print_cf_string("uid", uid);
        printf(" ");
        print_cf_string("manufacturer", manufacturer);
        printf(" input_channels=%u output_channels=%u sample_rate=%.0f\n",
               channel_count(devices[i], kAudioDevicePropertyScopeInput),
               channel_count(devices[i], kAudioDevicePropertyScopeOutput),
               nominal_sample_rate(devices[i]));
        if (name) CFRelease(name);
        if (uid) CFRelease(uid);
        if (manufacturer) CFRelease(manufacturer);
    }
    free(devices);
    return 0;
}

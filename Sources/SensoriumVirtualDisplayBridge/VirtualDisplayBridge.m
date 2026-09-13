#import "SensoriumVirtualDisplayBridge.h"
#import <Foundation/Foundation.h>

@interface NSObject (SensoriumVirtualDisplayRuntime)
- (instancetype)initWithWidth:(int32_t)width
                        height:(int32_t)height
                   refreshRate:(double)refreshRate;
- (instancetype)initWithDescriptor:(id)descriptor;
- (void)applySettings:(id)settings;
@end

int sensorium_virtual_display_runtime_available(void) {
    return (NSClassFromString(@"CGVirtualDisplayDescriptor") &&
            NSClassFromString(@"CGVirtualDisplayMode") &&
            NSClassFromString(@"CGVirtualDisplaySettings") &&
            NSClassFromString(@"CGVirtualDisplay")) ? 1 : 0;
}

void *sensorium_create_virtual_display(const char *name,
                                        int32_t logical_width,
                                        int32_t logical_height,
                                        int32_t pixel_width,
                                        int32_t pixel_height,
                                        uint32_t vendor_id,
                                        uint32_t product_id,
                                        uint32_t serial_number,
                                        uint32_t *display_id) {
    @autoreleasepool {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
            return NULL;
        }

        NSString *displayName = name ? @(name) : nil;
        if (!displayName) {
            return NULL;
        }

        // These runtime classes are undocumented and observed only on Apple
        // silicon; their key-value coding shape on hardware this has never
        // run on is unproven. A KVC
        // key that turns out not to exist there raises an NSException, which
        // terminates the process unless caught -- exactly the "crash through"
        // this bridge must not do. Every call that could raise one is inside
        // this @try, so a genuinely unsupported host fails the same way a
        // simply-missing class does: NULL, never a crash.
        @try {
            id descriptor = [[descriptorClass alloc] init];
            [descriptor setValue:displayName forKey:@"name"];
            [descriptor setValue:@(vendor_id) forKey:@"vendorID"];
            [descriptor setValue:@(product_id) forKey:@"productID"];
            [descriptor setValue:@(serial_number) forKey:@"serialNumber"];
            [descriptor setValue:@(pixel_width) forKey:@"maxPixelsWide"];
            [descriptor setValue:@(pixel_height) forKey:@"maxPixelsHigh"];
            [descriptor setValue:[NSValue valueWithSize:NSMakeSize(286, 179)]
                          forKey:@"sizeInMillimeters"];

            id mode = [[modeClass alloc] initWithWidth:pixel_width
                                                height:pixel_height
                                           refreshRate:60.0];
            if (!mode) {
                return NULL;
            }

            id settings = [[settingsClass alloc] init];
            [settings setValue:@YES forKey:@"hiDPI"];
            [settings setValue:@[mode] forKey:@"modes"];

            id display = [[displayClass alloc] initWithDescriptor:descriptor];
            if (!display) {
                return NULL;
            }
            [display applySettings:settings];
            uint32_t identifier = [[display valueForKey:@"displayID"] unsignedIntValue];
            if (identifier == 0) {
                return NULL;
            }

            if (display_id) {
                *display_id = identifier;
            }
            return (__bridge_retained void *)display;
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

void sensorium_destroy_virtual_display(void *display_handle) {
    if (!display_handle) {
        return;
    }

    // The display goes away here, not whenever an autorelease pool somewhere
    // above happens to drain. Hosting starts before this process has a run
    // loop, so a display left to a pool would live as long as the process,
    // holding its identity against every later canvas that asks for it. A
    // strong local takes the +1 the handle carries and gives it up at the end
    // of this scope, and the pool below drains anything the release itself
    // autoreleases. The @try is the same guard creation uses: an undocumented
    // class must not be able to take the process down.
    @autoreleasepool {
        @try {
            id display = (__bridge_transfer id)display_handle;
            (void)display;
        } @catch (NSException *exception) {
        }
    }
}

int sensorium_virtual_display_get_metrics(void *display_handle,
                                           uint32_t *max_pixels_wide,
                                           uint32_t *max_pixels_high,
                                           uint32_t *hi_dpi_scale) {
    if (!display_handle) {
        return 0;
    }

    @autoreleasepool {
        // Key-value coding on the same undocumented class creation guards. A
        // key that is not there on this machine raises an NSException, and
        // reporting no metrics is the only alternative to the process dying on
        // it.
        @try {
            id display = (__bridge id)display_handle;
            if (max_pixels_wide) {
                *max_pixels_wide = [[display valueForKey:@"maxPixelsWide"] unsignedIntValue];
            }
            if (max_pixels_high) {
                *max_pixels_high = [[display valueForKey:@"maxPixelsHigh"] unsignedIntValue];
            }
            if (hi_dpi_scale) {
                *hi_dpi_scale = [[display valueForKey:@"hiDPI"] unsignedIntValue];
            }
            return 1;
        } @catch (NSException *exception) {
            return 0;
        }
    }
}

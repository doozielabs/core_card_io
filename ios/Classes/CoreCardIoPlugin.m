#import "CoreCardIoPlugin.h"
#import <CardIO/CardIO.h>
#import <AVFoundation/AVFoundation.h>

@interface CoreCardIoPlugin ()<CardIOPaymentViewControllerDelegate>
@end

@implementation CoreCardIoPlugin {
    FlutterResult _result;
    UIViewController *_scanViewController;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // Ensure this matches your Dart file's channel name
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"core_card_io_beta"
            binaryMessenger:[registrar messenger]];
            
  CoreCardIoPlugin* instance = [[CoreCardIoPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSLog(@"[CoreCardIO] Plugin initialized. Preloading CardIO...");
        [CardIOUtilities preloadCardIO];
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSLog(@"[CoreCardIO] Method Channel received call: %@", call.method);

  if ([@"scanCard" isEqualToString:call.method]) {
      _result = result;
      [self scanCard:call.arguments];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)scanCard:(NSDictionary*)arguments {
    NSLog(@"[CoreCardIO] scanCard processing started.");

    // 1. Check Camera Availability
    BOOL canRead = [CardIOUtilities canReadCardWithCamera];
    if (!canRead) {
        NSLog(@"[CoreCardIO] WARNING: CardIOUtilities says it cannot read card with camera.");
    }
    
    // 2. Ensure UI work is done on the MAIN THREAD
    dispatch_async(dispatch_get_main_queue(), ^{
        
        CardIOPaymentViewController *scanViewController = [[CardIOPaymentViewController alloc] initWithPaymentDelegate:self];
        
        // --- Safe Property Extraction ---
        if ([self isNonNull:arguments[@"guideColor"]]) {
            scanViewController.guideColor = [self colorFromHex:arguments[@"guideColor"]];
        }
        
        scanViewController.hideCardIOLogo = [self safeBool:arguments forKey:@"hideCardIOLogo" defaultsTo:NO];
        scanViewController.useCardIOLogo = [self safeBool:arguments forKey:@"useCardIOLogo" defaultsTo:NO];
        scanViewController.disableManualEntryButtons = [self safeBool:arguments forKey:@"suppressManualEntry" defaultsTo:NO];
        scanViewController.suppressScanConfirmation = [self safeBool:arguments forKey:@"suppressConfirmation" defaultsTo:NO];
        scanViewController.scanExpiry = [self safeBool:arguments forKey:@"scanExpiry" defaultsTo:YES];
        
        if ([self isNonNull:arguments[@"scanInstructions"]]) {
            scanViewController.scanInstructions = arguments[@"scanInstructions"];
        }
        
        if ([self isNonNull:arguments[@"scannedImageDuration"]]) {
            scanViewController.scannedImageDuration = [arguments[@"scannedImageDuration"] doubleValue];
        }
        
        scanViewController.modalPresentationStyle = UIModalPresentationFullScreen;
        _scanViewController = scanViewController;
        
        // 3. Find the best View Controller to present on
        UIViewController *topController = [self topViewController];
        
        if (topController) {
            NSLog(@"[CoreCardIO] Presenting Camera Scanner...");
            [topController presentViewController:scanViewController animated:YES completion:^{
                NSLog(@"[CoreCardIO] Presentation COMPLETED. View should be visible.");
                // 4. Apply the Autofocus Fix for iPhone 14 Pro/17
                [self applyAutofocusFix];
            }];
        } else {
            NSLog(@"[CoreCardIO] ERROR: Could not find a root view controller.");
            if (_result) {
                _result([FlutterError errorWithCode:@"presentation_error" message:@"Could not find root view controller" details:nil]);
                _result = nil;
            }
        }
    });
}

// --- Helper Methods for Safety ---

- (BOOL)isNonNull:(id)value {
    return value != nil && value != [NSNull null];
}

- (BOOL)safeBool:(NSDictionary *)dict forKey:(NSString *)key defaultsTo:(BOOL)fallback {
    id value = dict[key];
    if ([self isNonNull:value]) {
        if ([value respondsToSelector:@selector(boolValue)]) {
            return [value boolValue];
        }
    }
    return fallback;
}

// Helper to find the correct window and root controller
- (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) {
                        window = w;
                        break;
                    }
                }
            }
            if (window) break;
        }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window) return nil;
    
    return [self findTopViewController:window.rootViewController];
}

- (UIViewController *)findTopViewController:(UIViewController *)root {
    if ([root isKindOfClass:[UINavigationController class]]) {
        return [self findTopViewController:[(UINavigationController *)root visibleViewController]];
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return [self findTopViewController:[(UITabBarController *)root selectedViewController]];
    }
    if (root.presentedViewController) {
        return [self findTopViewController:root.presentedViewController];
    }
    return root;
}

// The Camera Fix logic
- (void)applyAutofocusFix {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (@available(iOS 15.0, *)) {
            AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            if (device && device.minimumFocusDistance > 100) {
                NSError *error = nil;
                if ([device lockForConfiguration:&error]) {
                    CGFloat zoomFactor = 2.0;
                    if (zoomFactor <= device.activeFormat.videoMaxZoomFactor) {
                        device.videoZoomFactor = zoomFactor;
                        NSLog(@"[CoreCardIO] Autofocus Fix: Zoomed to 2.0x");
                    }
                    [device unlockForConfiguration];
                }
            }
        }
    });
}

#pragma mark - CardIOPaymentViewControllerDelegate

- (void)userDidCancelPaymentViewController:(CardIOPaymentViewController *)scanViewController {
    NSLog(@"[CoreCardIO] User cancelled.");
    [scanViewController dismissViewControllerAnimated:YES completion:nil];
    if (_result) {
        _result(nil);
        _result = nil;
    }
}

- (void)userDidProvideCreditCardInfo:(CardIOCreditCardInfo *)info inPaymentViewController:(CardIOPaymentViewController *)scanViewController {
    NSLog(@"[CoreCardIO] Card info received.");
    NSMutableDictionary *cardInfo = [NSMutableDictionary dictionary];
    
    if (info.cardNumber) cardInfo[@"cardNumber"] = info.cardNumber;
    if (info.redactedCardNumber) cardInfo[@"redactedCardNumber"] = info.redactedCardNumber;
    if (info.expiryMonth > 0) cardInfo[@"expiryMonth"] = @(info.expiryMonth);
    if (info.expiryYear > 0) cardInfo[@"expiryYear"] = @(info.expiryYear);
    if (info.cvv) cardInfo[@"cvv"] = info.cvv;
    if (info.postalCode) cardInfo[@"postalCode"] = info.postalCode;
    if (info.cardholderName) cardInfo[@"cardholderName"] = info.cardholderName;
    
    // FIX: Map values to match Dart enum expectations (lower camelCase)
    cardInfo[@"cardType"] = [self formatCardType:info.cardType];

    [scanViewController dismissViewControllerAnimated:YES completion:nil];
    
    if (_result) {
        _result(cardInfo);
        _result = nil;
    }
}

#pragma mark - Helper Methods

- (UIColor *)colorFromHex:(NSString *)hexString {
    if (![self isNonNull:hexString]) return [UIColor greenColor]; // Default
    
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    if ([hexString hasPrefix:@"#"]) {
        [scanner setScanLocation:1];
    }
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                           green:((rgbValue & 0xFF00) >> 8)/255.0
                            blue:(rgbValue & 0xFF)/255.0
                           alpha:1.0];
}

// FIX: Updated strings to match Dart enum values
- (NSString *)formatCardType:(CardIOCreditCardType)type {
    switch(type) {
        case CardIOCreditCardTypeVisa: return @"visa";
        case CardIOCreditCardTypeMastercard: return @"masterCard";
        case CardIOCreditCardTypeAmex: return @"amex";
        case CardIOCreditCardTypeDiscover: return @"discover";
        case CardIOCreditCardTypeJCB: return @"jcb";
        default: return @"unknown";
    }
}

@end
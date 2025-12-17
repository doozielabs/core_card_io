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
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"core_card_io"
            binaryMessenger:[registrar messenger]];
  CoreCardIoPlugin* instance = [[CoreCardIoPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Preload CardIO to make the launch faster and smoother
        [CardIOUtilities preloadCardIO];
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"scanCard" isEqualToString:call.method]) {
      _result = result;
      [self scanCard:call.arguments];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)scanCard:(NSDictionary*)arguments {
    CardIOPaymentViewController *scanViewController = [[CardIOPaymentViewController alloc] initWithPaymentDelegate:self];
    
    // --- Mapped Properties ---
    if (arguments[@"guideColor"]) {
        scanViewController.guideColor = [self colorFromHex:arguments[@"guideColor"]];
    }
    if (arguments[@"hideCardIOLogo"]) {
        scanViewController.hideCardIOLogo = [arguments[@"hideCardIOLogo"] boolValue];
    }
    if (arguments[@"useCardIOLogo"]) {
        scanViewController.useCardIOLogo = [arguments[@"useCardIOLogo"] boolValue];
    }
    
    // Correctly mapped properties for iOS SDK
    if (arguments[@"suppressManualEntry"]) {
        scanViewController.disableManualEntryButtons = [arguments[@"suppressManualEntry"] boolValue];
    }
    if (arguments[@"suppressConfirmation"]) {
        scanViewController.suppressScanConfirmation = [arguments[@"suppressConfirmation"] boolValue];
    }
    
    // These properties are Android-only or not available on iOS CardIOPaymentViewController
    // scanViewController.requireExpiry = ... (Not supported on iOS)
    // scanViewController.requireCVV = ... (Not supported on iOS)
    // scanViewController.requirePostalCode = ... (Not supported on iOS)
    
    if (arguments[@"scanExpiry"]) {
        scanViewController.scanExpiry = [arguments[@"scanExpiry"] boolValue];
    }
    if (arguments[@"scanInstructions"]) {
        scanViewController.scanInstructions = arguments[@"scanInstructions"];
    }
    if (arguments[@"scannedImageDuration"]) {
        scanViewController.scannedImageDuration = [arguments[@"scannedImageDuration"] doubleValue];
    }
    
    scanViewController.modalPresentationStyle = UIModalPresentationFullScreen;
    
    _scanViewController = scanViewController;
    
    // FIX: Get the correct top-most View Controller to present from
    UIViewController *topController = [self topViewController];
    
    if (topController) {
        [topController presentViewController:scanViewController animated:YES completion:^{
            // Apply the autofocus fix for newer iPhones (14 Pro, 15 Pro, 17, etc.)
            [self applyAutofocusFix];
        }];
    } else {
        NSLog(@"[CoreCardIO] Error: Could not find a root view controller to present the camera.");
        if (_result) {
            _result([FlutterError errorWithCode:@"presentation_error" message:@"Could not find root view controller" details:nil]);
            _result = nil;
        }
    }
}

// Helper to find the correct window and root controller (Handle iOS 13+ Scenes)
- (UIViewController *)topViewController {
    UIWindow *window = nil;
    
    // 1. Try to find the active window in iOS 13+ Scenes
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
    
    // 2. Fallback to legacy keyWindow
    if (!window) {
        window = [UIApplication sharedApplication].keyWindow;
    }
    
    if (!window) {
        return nil;
    }
    
    return [self findTopViewController:window.rootViewController];
}

// Recursively find the top-most view controller (handle Navigation, TabBar, Modals)
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

// The Camera Fix for iPhone 14 Pro / 15 Pro / 17
- (void)applyAutofocusFix {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (@available(iOS 15.0, *)) {
            AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            if (device) {
                // If minimum focus distance is high (approx > 100mm), it's a newer "Pro" sensor
                if (device.minimumFocusDistance > 100) {
                    NSError *error = nil;
                    if ([device lockForConfiguration:&error]) {
                        // 2.0x zoom forces the user to move back, putting the card in focus
                        CGFloat zoomFactor = 2.0;
                        if (zoomFactor <= device.activeFormat.videoMaxZoomFactor) {
                            device.videoZoomFactor = zoomFactor;
                        }
                        [device unlockForConfiguration];
                    }
                }
            }
        }
    });
}

#pragma mark - CardIOPaymentViewControllerDelegate

- (void)userDidCancelPaymentViewController:(CardIOPaymentViewController *)scanViewController {
    [scanViewController dismissViewControllerAnimated:YES completion:nil];
    if (_result) {
        _result(nil);
        _result = nil;
    }
}

- (void)userDidProvideCreditCardInfo:(CardIOCreditCardInfo *)info inPaymentViewController:(CardIOPaymentViewController *)scanViewController {
    NSMutableDictionary *cardInfo = [NSMutableDictionary dictionary];
    
    if (info.cardNumber) cardInfo[@"cardNumber"] = info.cardNumber;
    if (info.redactedCardNumber) cardInfo[@"redactedCardNumber"] = info.redactedCardNumber;
    if (info.expiryMonth > 0) cardInfo[@"expiryMonth"] = @(info.expiryMonth);
    if (info.expiryYear > 0) cardInfo[@"expiryYear"] = @(info.expiryYear);
    if (info.cvv) cardInfo[@"cvv"] = info.cvv;
    if (info.postalCode) cardInfo[@"postalCode"] = info.postalCode;
    if (info.cardholderName) cardInfo[@"cardholderName"] = info.cardholderName;
    
    cardInfo[@"cardType"] = [self formatCardType:info.cardType];

    [scanViewController dismissViewControllerAnimated:YES completion:nil];
    
    if (_result) {
        _result(cardInfo);
        _result = nil;
    }
}

#pragma mark - Helper Methods

- (UIColor *)colorFromHex:(NSString *)hexString {
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

- (NSString *)formatCardType:(CardIOCreditCardType)type {
    switch(type) {
        case CardIOCreditCardTypeVisa: return @"Visa";
        case CardIOCreditCardTypeMastercard: return @"MasterCard";
        case CardIOCreditCardTypeAmex: return @"Amex";
        case CardIOCreditCardTypeDiscover: return @"Discover";
        case CardIOCreditCardTypeJCB: return @"JCB";
        default: return @"Unknown";
    }
}

@end
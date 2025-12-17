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

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"scanCard" isEqualToString:call.method]) {
      _result = result;
      [self scanCard:call.arguments];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)scanCard:(NSDictionary*)arguments {
    // 1. Use the STANDARD CardIOPaymentViewController (Reverted from subclass to fix "screen not showing")
    CardIOPaymentViewController *scanViewController = [[CardIOPaymentViewController alloc] initWithPaymentDelegate:self];
    
    // --- Mapped Properties (fixes property not found errors) ---
    
    if (arguments[@"guideColor"]) {
        scanViewController.guideColor = [self colorFromHex:arguments[@"guideColor"]];
    }
    if (arguments[@"hideCardIOLogo"]) {
        scanViewController.hideCardIOLogo = [arguments[@"hideCardIOLogo"] boolValue];
    }
    if (arguments[@"useCardIOLogo"]) {
        scanViewController.useCardIOLogo = [arguments[@"useCardIOLogo"] boolValue];
    }
    
    // Map "suppressManualEntry" to "disableManualEntryButtons"
    if (arguments[@"suppressManualEntry"]) {
        scanViewController.disableManualEntryButtons = [arguments[@"suppressManualEntry"] boolValue];
    }
    
    // Map "suppressConfirmation" to "suppressScanConfirmation"
    if (arguments[@"suppressConfirmation"]) {
        scanViewController.suppressScanConfirmation = [arguments[@"suppressConfirmation"] boolValue];
    }
    
    // Note: 'requireExpiry', 'requireCVV', 'requirePostalCode' are intentionally omitted
    // as they are not supported on the iOS CardIOPaymentViewController class.
    
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
    
    UIViewController *rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
    
    // 2. Present the controller, then apply the fix in the completion block
    [rootViewController presentViewController:scanViewController animated:YES completion:^{
        [self applyAutofocusFix];
    }];
}

// 3. The Camera Fix: Force Zoom 2x on newer devices (iOS 15+)
- (void)applyAutofocusFix {
    // We use a small delay to ensure CardIO has fully started its AVCaptureSession
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (@available(iOS 15.0, *)) {
            AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            if (device) {
                // Check if device supports focus distance (approx proxy for "Pro" cameras or newer sensors)
                BOOL isNewerDevice = (device.minimumFocusDistance > 100); 
                
                if (isNewerDevice) {
                    NSError *error = nil;
                    if ([device lockForConfiguration:&error]) {
                        // 2.0x zoom allows the user to hold the card further away, 
                        // bypassing the minimum focus distance limit of newer sensors.
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
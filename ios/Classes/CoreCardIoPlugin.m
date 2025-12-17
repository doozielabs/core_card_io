#import "CoreCardIoPlugin.h"
#import <CardIO/CardIO.h>
#import <AVFoundation/AVFoundation.h>

// 1. Define the interface for the custom View Controller
@interface FixedCardIOPaymentViewController : CardIOPaymentViewController
- (void)applyAutofocusFix;
@end

@implementation FixedCardIOPaymentViewController

// 2. Define the helper method first so it is visible to viewWillAppear
- (void)applyAutofocusFix {
    if (@available(iOS 15.0, *)) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (device) {
            NSError *error = nil;
            // Check if the device supports focusing and has a large minimum focus distance
            // (150mm is roughly the threshold where issues start occurring on Pro models)
            BOOL isProDevice = (device.minimumFocusDistance > 150);
            
            if (isProDevice) {
                if ([device lockForConfiguration:&error]) {
                    // Set zoom factor to 2.0x to allow holding the phone further away
                    // This brings the card back to full size while respecting focus distance.
                    CGFloat zoomFactor = 2.0;
                    if (zoomFactor <= device.activeFormat.videoMaxZoomFactor) {
                        device.videoZoomFactor = zoomFactor;
                    }
                    [device unlockForConfiguration];
                }
            }
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Now the compiler knows about this method
    [self applyAutofocusFix];
}

@end

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
    // Use the custom subclass FixedCardIOPaymentViewController
    FixedCardIOPaymentViewController *scanViewController = [[FixedCardIOPaymentViewController alloc] initWithPaymentDelegate:self];
    
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
    
    // FIX 1: Map "suppressManualEntry" to "disableManualEntryButtons"
    if (arguments[@"suppressManualEntry"]) {
        scanViewController.disableManualEntryButtons = [arguments[@"suppressManualEntry"] boolValue];
    }
    
    // FIX 2: Map "suppressConfirmation" to "suppressScanConfirmation"
    if (arguments[@"suppressConfirmation"]) {
        scanViewController.suppressScanConfirmation = [arguments[@"suppressConfirmation"] boolValue];
    }
    
    // NOTE: 'requireExpiry', 'requireCVV', 'requirePostalCode' are not supported properties 
    // on the iOS CardIOPaymentViewController and have been removed to fix build errors.
    
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
    [rootViewController presentViewController:scanViewController animated:YES completion:nil];
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
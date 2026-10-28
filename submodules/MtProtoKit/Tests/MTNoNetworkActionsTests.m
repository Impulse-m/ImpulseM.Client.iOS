#import <XCTest/XCTest.h>

#import <MtProtoKit/MTDatacenterAuthAction.h>
#import <MtProtoKit/MTDatacenterTransferAuthAction.h>

#import "MTTestSupport.h"

// A context that another engine carries makes its default key and transfer actions without a network request,
// before any engine is activated. Every outcome here is synchronous: the actions report at once, so nothing waits.

@interface MTNoNetworkTransferDelegate : NSObject <MTDatacenterTransferAuthActionDelegate>

@property (nonatomic, readonly) NSUInteger completedCount;
@property (nonatomic, readonly) NSUInteger failedCount;

@end

@implementation MTNoNetworkTransferDelegate

- (void)datacenterTransferAuthActionCompleted:(MTDatacenterTransferAuthAction *)action {
    _completedCount += 1;
}

- (void)datacenterTransferAuthActionFailed:(MTDatacenterTransferAuthAction *)action {
    _failedCount += 1;
}

@end

@interface MTNoNetworkActionsTests : XCTestCase
@end

@implementation MTNoNetworkActionsTests

- (void)testSwitchMakesNoNetworkAuthAction {
    MTContext *context = MTTestMakeContext(false);
    context.disablesNetworkActions = true;

    __block NSUInteger completionCount = 0;
    __block bool completionSucceeded = true;
    MTDatacenterAuthAction *action = [context makeAuthActionWithSelector:MTDatacenterAuthInfoSelectorPersistent isCdn:false skipBind:false completion:^(MTDatacenterAuthAction *completed, bool success) {
        completionCount += 1;
        completionSucceeded = success;
    }];

    XCTAssertFalse([action isMemberOfClass:[MTDatacenterAuthAction class]]);

    [action execute:context datacenterId:1];

    XCTAssertEqual(completionCount, 1);
    XCTAssertFalse(completionSucceeded);
}

- (void)testSwitchMakesNoNetworkTransferAction {
    MTContext *context = MTTestMakeContext(false);
    context.disablesNetworkActions = true;

    MTDatacenterTransferAuthAction *action = [context makeTransferAuthAction];
    XCTAssertFalse([action isMemberOfClass:[MTDatacenterTransferAuthAction class]]);

    MTNoNetworkTransferDelegate *delegate = [[MTNoNetworkTransferDelegate alloc] init];
    action.delegate = delegate;
    [action execute:context masterDatacenterId:1 destinationDatacenterId:2 authToken:@"token"];

    XCTAssertEqual(delegate.failedCount, 1);
    XCTAssertEqual(delegate.completedCount, 0);
}

- (void)testDefaultContextKeepsNetworkActions {
    MTContext *context = MTTestMakeContext(false);
    XCTAssertFalse(context.disablesNetworkActions);

    MTDatacenterAuthAction *authAction = [context makeAuthActionWithSelector:MTDatacenterAuthInfoSelectorPersistent isCdn:false skipBind:false completion:^(MTDatacenterAuthAction *completed, bool success) {
    }];
    XCTAssertTrue([authAction isMemberOfClass:[MTDatacenterAuthAction class]]);

    MTDatacenterTransferAuthAction *transferAction = [context makeTransferAuthAction];
    XCTAssertTrue([transferAction isMemberOfClass:[MTDatacenterTransferAuthAction class]]);
}

- (void)testInstalledFactoryWinsOverSwitch {
    MTContext *context = MTTestMakeContext(false);
    context.disablesNetworkActions = true;
    context.authActionFactory = ^MTDatacenterAuthAction *(MTDatacenterAuthInfoSelector selector, bool isCdn, bool skipBind, void (^completion)(MTDatacenterAuthAction *, bool)) {
        return [[MTTestAuthAction alloc] initWithSelector:selector completion:completion onExecute:nil];
    };

    MTDatacenterAuthAction *action = [context makeAuthActionWithSelector:MTDatacenterAuthInfoSelectorPersistent isCdn:false skipBind:false completion:^(MTDatacenterAuthAction *completed, bool success) {
    }];
    XCTAssertTrue([action isKindOfClass:[MTTestAuthAction class]]);

    context.authActionFactory = nil;
}

@end

#import "TGGenericPeerMediaGalleryModel.h"

#import "ActionStage.h"
#import "SGraphObjectNode.h"

#import "ATQueue.h"

#import "TGDatabase.h"
#import "TGAppDelegate.h"
#import "TGTelegraph.h"

#import "TGGenericPeerMediaGalleryImageItem.h"
#import "TGGenericPeerMediaGalleryVideoItem.h"

#import "TGGenericPeerMediaGalleryDefaultHeaderView.h"
#import "TGGenericPeerMediaGalleryDefaultFooterView.h"
#import "TGGenericPeerMediaGalleryActionsAccessoryView.h"
#import "TGGenericPeerMediaGalleryDeleteAccessoryView.h"

#import "TGStringUtils.h"
#import "TGActionSheet.h"

#import "ActionStage.h"

#import <AssetsLibrary/AssetsLibrary.h>

#import "TGForwardTargetController.h"
#import "TGUsernameController.h"
#import "TGProgressWindow.h"

#import "TGAlertView.h"
#import "TGImageManager.h"
#import "ZXingObjC.h"
#import "TGInterfaceManager.h"

#import "T8GroupHttpRequestService.h"
#import "TGReplyGroupViewController.h"

@interface TGGenericPeerMediaGalleryModel () <ASWatcher>
{
    ATQueue *_queue;
    
    NSArray *_modelItems;
    int32_t _atMessageId;
    bool _allowActions;
    
    NSUInteger _incompleteCount;
    bool _loadingCompleted;
    bool _loadingCompletedInternal;
}

@property (nonatomic, strong) ASHandle *actionHandle;

@end

@implementation TGGenericPeerMediaGalleryModel

- (instancetype)initWithPeerId:(int64_t)peerId atMessageId:(int32_t)atMessageId allowActions:(bool)allowActions
{
    self = [super init];
    if (self != nil)
    {
        _actionHandle = [[ASHandle alloc] initWithDelegate:self];
        
        _queue = [[ATQueue alloc] init];
        
        _peerId = peerId;
        
        _atMessageId = atMessageId;
        _allowActions = allowActions;
        [self _loadInitialItemsAtMessageId:_atMessageId];
            
        [ActionStageInstance() watchForPaths:@[
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messages", _peerId],
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messagesChanged", _peerId],
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messagesDeleted", _peerId]
        ] watcher:self];
    }
    return self;
}

- (void)dealloc
{
    [_actionHandle reset];
    [ActionStageInstance() removeWatcher:self];
}

- (void)_transitionCompleted
{
    [super _transitionCompleted];
    
    [_queue dispatch:^
    {
        NSArray *messages = [[TGDatabaseInstance() loadMediaInConversation:_peerId maxMid:INT_MAX maxLocalMid:INT_MAX maxDate:INT_MAX limit:INT_MAX count:NULL] sortedArrayUsingComparator:^NSComparisonResult(TGMessage *message1, TGMessage *message2)
        {
            NSTimeInterval date1 = message1.date;
            NSTimeInterval date2 = message2.date;
            
            if (ABS(date1 - date2) < DBL_EPSILON)
            {
                if (message1.mid > message2.mid)
                    return NSOrderedAscending;
                else
                    return NSOrderedDescending;
            }
            
            return date1 > date2 ? NSOrderedAscending : NSOrderedDescending;
        }];
        
        _loadingCompletedInternal = true;
        
        TGDispatchOnMainThread(^
        {
            _loadingCompleted = true;
        });
        
        [self _replaceMessages:messages atMessageId:_atMessageId];
    }];
    
    [ActionStageInstance() requestActor:[[NSString alloc] initWithFormat:@"/tg/updateMediaHistory/(%" PRIx64 ")", _peerId] options:@{@"peerId": @(_peerId)} flags:0 watcher:self];
}

- (void)_loadInitialItemsAtMessageId:(int32_t)atMessageId
{
    int count = 0;
    NSArray *messages = [[TGDatabaseInstance() loadMediaInConversation:_peerId atMessageId:atMessageId limitAfter:32 count:&count] sortedArrayUsingComparator:^NSComparisonResult(TGMessage *message1, TGMessage *message2)
    {
        NSTimeInterval date1 = message1.date;
        NSTimeInterval date2 = message2.date;
        
        if (ABS(date1 - date2) < DBL_EPSILON)
        {
            if (message1.mid > message2.mid)
                return NSOrderedAscending;
            else
                return NSOrderedDescending;
        }
        
        return date1 > date2 ? NSOrderedAscending : NSOrderedDescending;
    }];
    
    _incompleteCount = count;
    
    [self _replaceMessages:messages atMessageId:atMessageId];
}

- (void)_addMessages:(NSArray *)messages
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
    
    NSMutableSet *currentMessageIds = [[NSMutableSet alloc] init];
    for (id<TGGenericPeerGalleryItem> item in updatedModelItems)
    {
        [currentMessageIds addObject:@([item messageId])];
    }
    
    for (TGMessage *message in messages)
    {
        if ([currentMessageIds containsObject:@(message.mid)])
            continue;
        
        for (id attachment in message.mediaAttachments)
        {
            if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
            {
                TGImageMediaAttachment *imageMedia = attachment;
                
                NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                
                int64_t localImageId = 0;
                if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                    localImageId = murMurHash32(legacyCacheUrl);
                
                TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                imageItem.date = message.date;
                imageItem.messageId = message.mid;
                [updatedModelItems addObject:imageItem];
            }
            else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
            {
                TGVideoMediaAttachment *videoMedia = attachment;
                TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                videoItem.date = message.date;
                videoItem.messageId = message.mid;
                [updatedModelItems addObject:videoItem];
            }
        }
    }
    
    [updatedModelItems sortUsingComparator:^NSComparisonResult(id<TGGenericPeerGalleryItem> item1, id<TGGenericPeerGalleryItem> item2)
    {
        NSTimeInterval date1 = [item1 date];
        NSTimeInterval date2 = [item2 date];
        
        if (ABS(date1 - date2) < DBL_EPSILON)
        {
            if ([item1 messageId] < [item2 messageId])
                return NSOrderedAscending;
            else
                return NSOrderedDescending;
        }
        
        return date1 < date2 ? NSOrderedAscending : NSOrderedDescending;
    }];
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:nil];
}

- (void)_deleteMessagesWithIds:(NSArray *)messageIds
{
    NSMutableSet *messageIdsSet = [[NSMutableSet alloc] init];
    for (NSNumber *nMid in messageIds)
    {
        [messageIdsSet addObject:nMid];
    }
    
    NSMutableIndexSet *indexSet = [[NSMutableIndexSet alloc] init];
    NSInteger index = -1;
    for (id<TGGenericPeerGalleryItem> item in _modelItems)
    {
        index++;
        if ([messageIdsSet containsObject:@([item messageId])])
        {
            [indexSet addIndex:(NSUInteger)index];
        }
    }
    
    if (indexSet.count != 0)
    {
        NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
        [updatedModelItems removeObjectsAtIndexes:indexSet];
        _modelItems = updatedModelItems;
        
        [self _replaceItems:_modelItems focusingOnItem:nil];
    }
}

- (void)_replaceMessagesWithNewMessages:(NSDictionary *)messagesById
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
    
    bool changesFound = false;
    for (NSInteger index = 0; index < (NSInteger)updatedModelItems.count; index++)
    {
        id<TGGenericPeerGalleryItem> item = updatedModelItems[index];
        
        if (messagesById[@([item messageId])] != nil)
        {
            TGMessage *message = messagesById[@([item messageId])];
            
            for (id attachment in message.mediaAttachments)
            {
                if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
                {
                    TGImageMediaAttachment *imageMedia = attachment;
                    
                    NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                    
                    int64_t localImageId = 0;
                    if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                        localImageId = murMurHash32(legacyCacheUrl);
                    
                    TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                    imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                    imageItem.date = message.date;
                    imageItem.messageId = message.mid;
                    
                    changesFound = true;
                    [updatedModelItems replaceObjectAtIndex:(NSUInteger)index withObject:imageItem];
                }
                else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
                {
                    TGVideoMediaAttachment *videoMedia = attachment;
                    TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                    videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                    videoItem.date = message.date;
                    videoItem.messageId = message.mid;

                    changesFound = true;
                    [updatedModelItems replaceObjectAtIndex:(NSUInteger)index withObject:videoItem];
                }
            }
        }
    }
    
    [updatedModelItems sortUsingComparator:^NSComparisonResult(id<TGGenericPeerGalleryItem> item1, id<TGGenericPeerGalleryItem> item2)
     {
         NSTimeInterval date1 = [item1 date];
         NSTimeInterval date2 = [item2 date];
         
         if (ABS(date1 - date2) < DBL_EPSILON)
         {
             if ([item1 messageId] < [item2 messageId])
                 return NSOrderedAscending;
             else
                 return NSOrderedDescending;
         }
         
         return date1 < date2 ? NSOrderedAscending : NSOrderedDescending;
     }];
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:nil];
}

- (void)_replaceMessages:(NSArray *)messages atMessageId:(int32_t)atMessageId
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] init];
    
    id<TGModernGalleryItem> focusItem = nil;
    
    for (TGMessage *message in messages)
    {
        for (id attachment in message.mediaAttachments)
        {
            if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
            {
                TGImageMediaAttachment *imageMedia = attachment;
                
                NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                
                int64_t localImageId = 0;
                if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                    localImageId = murMurHash32(legacyCacheUrl);
                
                TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                imageItem.date = message.date;
                imageItem.messageId = message.mid;
                [updatedModelItems insertObject:imageItem atIndex:0];
                
                if (atMessageId != 0 && atMessageId == message.mid)
                    focusItem = imageItem;
            }
            else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
            {
                TGVideoMediaAttachment *videoMedia = attachment;
                TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                videoItem.date = message.date;
                videoItem.messageId = message.mid;
                [updatedModelItems insertObject:videoItem atIndex:0];
                
                if (atMessageId != 0 && atMessageId == message.mid)
                    focusItem = videoItem;
            }
        }
    }
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:focusItem];
}

- (UIView<TGModernGalleryDefaultHeaderView> *)createDefaultHeaderView
{
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    return [[TGGenericPeerMediaGalleryDefaultHeaderView alloc] initWithPositionAndCountBlock:^(id<TGModernGalleryItem> item, NSUInteger *position, NSUInteger *count)
    {
        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            if (position != NULL)
            {
                NSUInteger index = [strongSelf.items indexOfObject:item];
                if (index != NSNotFound)
                {
                    *position = strongSelf->_loadingCompleted ? index : (strongSelf->_incompleteCount - strongSelf.items.count + index);
                }
            }
            if (count != NULL)
                *count = strongSelf->_loadingCompleted ? strongSelf.items.count : strongSelf->_incompleteCount;
        }
    }];
}

- (UIView<TGModernGalleryDefaultFooterView> *)createDefaultFooterView
{
    return [[TGGenericPeerMediaGalleryDefaultFooterView alloc] init];
}

- (UIView<TGModernGalleryDefaultFooterAccessoryView> *)createDefaultLeftAccessoryView
{
    if (!_allowActions)
        return nil;
    
    TGGenericPeerMediaGalleryActionsAccessoryView *accessoryView = [[TGGenericPeerMediaGalleryActionsAccessoryView alloc] init];
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    accessoryView.action = ^(id<TGModernGalleryItem> item)
    {
        if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)])
        {
            id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
            __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
            if (strongSelf != nil)
            {
                UIView *actionSheetView = nil;
                if (strongSelf.actionSheetView)
                    actionSheetView = strongSelf.actionSheetView();
                
                if (actionSheetView != nil)
                {
                    NSMutableArray *actions = [[NSMutableArray alloc] init];
                    
                    if ([strongSelf _isDataAvailableForSavingItemToCameraRoll:item])
                    {
                        if (([concreteItem isKindOfClass:[TGGenericPeerMediaGalleryImageItem class]] && (!TGAppDelegateInstance.autosavePhotos || [concreteItem author].uid == TGTelegraphInstance.clientUserId)) || [concreteItem isKindOfClass:[TGGenericPeerMediaGalleryVideoItem class]])
                        {
                            [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Preview.SaveToCameraRoll") action:@"save" type:TGActionSheetActionTypeGeneric]];
                        }
                    }
                    [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Preview.ForwardViaDove") action:@"forward" type:TGActionSheetActionTypeGeneric]];
                    [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Preview.QRCode") action:@"QRCode" type:TGActionSheetActionTypeGeneric]];
                    [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Common.Cancel") action:@"cancel" type:TGActionSheetActionTypeCancel]];
                    
                    [[[TGActionSheet alloc] initWithTitle:nil actions:actions actionBlock:^(__unused id target, NSString *action)
                    {
                        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
                        if ([action isEqualToString:@"save"])
                            [strongSelf _commitSaveItemToCameraRoll:item];
                        else if ([action isEqualToString:@"forward"])
                            [strongSelf _commitForwardItem:item];
                        else if ([action isEqualToString:@"QRCode"])
                            [strongSelf _readQRCode:item];
                    } target:strongSelf] showInView:actionSheetView];
                }
            }
        }
    };
    return accessoryView;
}

- (bool)_isDataAvailableForSavingItemToCameraRoll:(id<TGModernGalleryItem>)item
{
    if ([item isKindOfClass:[TGGenericPeerMediaGalleryImageItem class]])
    {
        TGGenericPeerMediaGalleryImageItem *imageItem = (TGGenericPeerMediaGalleryImageItem *)item;
        return [[NSFileManager defaultManager] fileExistsAtPath:[imageItem filePath]];
    }
    else if ([item isKindOfClass:[TGGenericPeerMediaGalleryVideoItem class]])
    {
        TGGenericPeerMediaGalleryVideoItem *videoItem = (TGGenericPeerMediaGalleryVideoItem *)item;
        return [[NSFileManager defaultManager] fileExistsAtPath:[videoItem filePath]];
    }
    
    return false;
}

- (void)_commitSaveItemToCameraRoll:(id<TGModernGalleryItem>)item
{
    if ([item isKindOfClass:[TGGenericPeerMediaGalleryImageItem class]])
    {
        TGGenericPeerMediaGalleryImageItem *imageItem = (TGGenericPeerMediaGalleryImageItem *)item;
        NSData *data = [[NSData alloc] initWithContentsOfFile:[imageItem filePath]];
        [self _saveImageDataToCameraRoll:data];
    }
    else if ([item isKindOfClass:[TGGenericPeerMediaGalleryVideoItem class]])
    {
        TGGenericPeerMediaGalleryVideoItem *videoItem = (TGGenericPeerMediaGalleryVideoItem *)item;
        [self _saveVideoToCameraRoll:[videoItem filePath]];
    }
}

- (void)_saveImageDataToCameraRoll:(NSData *)data
{
    if (data == nil)
        return;
    
    TGProgressWindow *progressWindow = [[TGProgressWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [progressWindow show:true];
    
    ALAssetsLibrary *assetsLibrary = [[ALAssetsLibrary alloc] init];
    
    __block __strong ALAssetsLibrary *blockLibrary = assetsLibrary;
    [assetsLibrary writeImageDataToSavedPhotosAlbum:data metadata:nil completionBlock:^(NSURL *assetURL, NSError *error)
    {
        TGDispatchOnMainThread(^
        {
            if (error != nil)
                [progressWindow dismiss:true];
            else
                [progressWindow dismissWithSuccess];
        });
        
        if (error != nil)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                TGAlertView *alertView = [[TGAlertView alloc] initWithTitle:nil message:@"An error occured" delegate:nil cancelButtonTitle:TGLocalized(@"Common.Cancel") otherButtonTitles:nil];
                [alertView show];
            });
        }
        else
        {
            TGLog(@"Saved to %@", assetURL);
        }
        
        blockLibrary = nil;
    }];
}

- (void)_saveVideoToCameraRoll:(NSString *)filePath
{
    if (filePath == nil)
        return;
    
    TGProgressWindow *progressWindow = [[TGProgressWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [progressWindow show:true];
    
    ALAssetsLibrary *assetsLibrary = [[ALAssetsLibrary alloc] init];
    
    __block __strong ALAssetsLibrary *blockLibrary = assetsLibrary;
    [assetsLibrary writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:filePath] completionBlock:^(NSURL *assetURL, NSError *error)
    {
        TGDispatchOnMainThread(^
        {
            if (error != nil)
                [progressWindow dismiss:true];
            else
                [progressWindow dismissWithSuccess];
        });

        if (error != nil)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                TGAlertView *alertView = [[TGAlertView alloc] initWithTitle:nil message:@"An error occured" delegate:nil cancelButtonTitle:TGLocalized(@"Common.Cancel") otherButtonTitles:nil];
                [alertView show];
            });
        }
        else
            TGLog(@"Saved to %@", assetURL);
        
        blockLibrary = nil;
    }];
}

- (void)_commitForwardItem:(id<TGModernGalleryItem>)item
{
    if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)])
    {
        id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
        
        TGDispatchOnMainThread(^
        {
            [[UIApplication sharedApplication] beginIgnoringInteractionEvents];
        });
        
        [ActionStageInstance() dispatchOnStageQueue:^
        {
            TGMessage *message = [TGDatabaseInstance() loadMessageWithMid:[concreteItem messageId]];
            if (message == nil)
                message = [TGDatabaseInstance() loadMediaMessageWithMid:[concreteItem messageId]];
            
            TGDispatchOnMainThread(^
            {
                [[UIApplication sharedApplication] endIgnoringInteractionEvents];
                
                UIViewController *viewController = nil;
                if (self.viewControllerForModalPresentation)
                    viewController = self.viewControllerForModalPresentation();
                
                if (viewController != nil && message != nil)
                {
                    TGForwardTargetController *forwardController = [[TGForwardTargetController alloc] initWithForwardMessages:[[NSArray alloc] initWithObjects:message, nil] sendMessages:nil];
                    forwardController.watcherHandle = _actionHandle;
                    TGNavigationController *navigationController = [TGNavigationController navigationControllerWithRootController:forwardController];
                    
                    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
                    {
                        navigationController.presentationStyle = TGNavigationControllerPresentationStyleInFormSheet;
                        navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
                    }
                    
                    [viewController presentViewController:navigationController animated:true completion:nil];
                }
            });
        }];
    }
}

- (void)_readQRCode:(id<TGModernGalleryItem>)item
{
    if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)]){
        id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
        TGMessage *message = [TGDatabaseInstance() loadMessageWithMid:[concreteItem messageId]];
        if (message == nil)
            message = [TGDatabaseInstance() loadMediaMessageWithMid:[concreteItem messageId]];
        if ([concreteItem isKindOfClass:[TGGenericPeerMediaGalleryImageItem class]]) {
            TGGenericPeerMediaGalleryImageItem *imageItem = (TGGenericPeerMediaGalleryImageItem *)concreteItem;
            NSString *asyncTaskId = nil;
            UIImage *image = [[TGImageManager instance] loadImageSyncWithUri:imageItem.uri canWait:true decode:true acceptPartialData:true asyncTaskId:&asyncTaskId progress:nil partialCompletion:nil completion:nil];
            CGImageRef imageToDecode = [image CGImage];  // Given a CGImage in which we are looking for barcodes
            
            ZXLuminanceSource *source = [[ZXCGImageLuminanceSource alloc] initWithCGImage:imageToDecode];
            ZXBinaryBitmap *bitmap = [ZXBinaryBitmap binaryBitmapWithBinarizer:[ZXHybridBinarizer binarizerWithSource:source]];
            
            NSError *error = nil;
            
            // There are a number of hints we can give to the reader, including
            // possible formats, allowed lengths, and the string encoding.
            ZXDecodeHints *hints = [ZXDecodeHints hints];
            
            ZXMultiFormatReader *reader = [ZXMultiFormatReader reader];
            ZXResult *result = [reader decode:bitmap
                                        hints:hints
                                        error:&error];
            if (result) {
                NSString *content = result.text;
                NSRegularExpression *regular = [NSRegularExpression regularExpressionWithPattern:@"^(.*?)chat_id=(.*?)&chat_name=(.*?)$" options:NSRegularExpressionCaseInsensitive error:nil];
                NSUInteger matches = [regular numberOfMatchesInString:content options:0 range:NSMakeRange(0, content.length)];
                if (matches == 0) {
                    return;
                }
                NSString *groupID = [regular stringByReplacingMatchesInString:content options:NSMatchingReportCompletion range:NSMakeRange(0, content.length) withTemplate:@"$2"];
                NSString *groupName = [regular stringByReplacingMatchesInString:content options:NSMatchingReportProgress range:NSMakeRange(0, content.length) withTemplate:@"$3"];
                
                NSNumber *groupIDNumber = nil;
                if (groupID.longLongValue > 0) {
                    groupIDNumber = @(-groupID.longLongValue);
                }else{
                    groupIDNumber = @(groupID.longLongValue);
                }
                
                if ((T8CONTEXT.username == nil) || [T8CONTEXT.username isEqualToString:@""])
                {
                    UIViewController *viewController = nil;
                    if (self.viewControllerForModalPresentation)
                        viewController = self.viewControllerForModalPresentation();

                    if (viewController != nil){
                        TGUsernameController *usernameController = [[TGUsernameController alloc] init];
                        
                        TGNavigationController *navigationController = [TGNavigationController navigationControllerWithControllers:@[usernameController]];
                        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
                            navigationController.restrictLandscape = false;
                        else
                        {
                            navigationController.presentationStyle = TGNavigationControllerPresentationStyleInFormSheet;
                            navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
                        }
                        
                        [viewController presentViewController:navigationController animated:true completion:nil];
                    }
                    
                }else{
//                    if ([TGDatabaseInstance() containsConversationWithId:groupIDNumber.longLongValue]) {
//                        [[TGInterfaceManager instance] navigateToConversationWithId:groupIDNumber.longLongValue conversation:nil];
//                    }else{
                        UIViewController *viewController = nil;
                        if (self.viewControllerForModalPresentation)
                            viewController = self.viewControllerForModalPresentation();
                        
                        if (viewController != nil){
                            TGReplyGroupViewController *replyGroupController = [[TGReplyGroupViewController alloc] initWithConversationId:groupIDNumber.longLongValue groupName:groupName groupAvatar:[UIImage imageNamed:@"dove_logo_still.png"] groupDescription:nil];
                            
                            TGNavigationController *navigationController = [TGNavigationController navigationControllerWithControllers:@[replyGroupController]];
                            
                            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
                            {
                                navigationController.presentationStyle = TGNavigationControllerPresentationStyleInFormSheet;
                                navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
                            }
                            
                            [viewController presentViewController:navigationController animated:true completion:nil];
                        }
//                    }
                }
            }
        }
    }
}

- (UIView<TGModernGalleryDefaultFooterAccessoryView> *)createDefaultRightAccessoryView
{
    TGGenericPeerMediaGalleryDeleteAccessoryView *accessoryView = [[TGGenericPeerMediaGalleryDeleteAccessoryView alloc] init];
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    accessoryView.action = ^(id<TGModernGalleryItem> item)
    {
        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            UIView *actionSheetView = nil;
            if (strongSelf.actionSheetView)
                actionSheetView = strongSelf.actionSheetView();
            
            if (actionSheetView != nil)
            {
                NSMutableArray *actions = [[NSMutableArray alloc] init];
                
                NSString *actionTitle = nil;
                if ([item isKindOfClass:[TGModernGalleryImageItem class]])
                    actionTitle = TGLocalized(@"Preview.DeletePhoto");
                else
                    actionTitle = TGLocalized(@"Preview.DeleteVideo");
                [actions addObject:[[TGActionSheetAction alloc] initWithTitle:actionTitle action:@"delete" type:TGActionSheetActionTypeDestructive]];
                [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Common.Cancel") action:@"cancel" type:TGActionSheetActionTypeCancel]];
                
                [[[TGActionSheet alloc] initWithTitle:nil actions:actions actionBlock:^(__unused id target, NSString *action)
                {
                    __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
                    if ([action isEqualToString:@"delete"])
                    {
                        [strongSelf _commitDeleteItem:item];
                    }
                } target:strongSelf] showInView:actionSheetView];
            }
        }
    };
    return accessoryView;
}

- (void)_commitDeleteItem:(id<TGModernGalleryItem>)item
{
    [_queue dispatch:^
    {
        if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)])
        {
            id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
            
            NSArray *messageIds = @[@([concreteItem messageId])];
            [self _deleteMessagesWithIds:messageIds];
            static int actionId = 1;
            [ActionStageInstance() requestActor:[NSString stringWithFormat:@"/tg/conversation/(%lld)/deleteMessages/(genericPeerMedia%d)", _peerId, actionId++] options:@{@"mids": messageIds} watcher:TGTelegraphInstance];
        }
    }];
}

- (void)actionStageResourceDispatched:(NSString *)path resource:(id)resource arguments:(id)__unused arguments
{
    if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messages", _peerId]])
    {
        [_queue dispatch:^
        {
            if (!_loadingCompletedInternal)
                return;
            
            NSArray *messages = [((SGraphObjectNode *)resource).object mutableCopy];
            [self _addMessages:messages];
        }];
    }
    else if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messagesChanged", _peerId]])
    {
        [_queue dispatch:^
        {
            NSArray *midMessagePairs = ((SGraphObjectNode *)resource).object;
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
            for (NSUInteger i = 0; i < midMessagePairs.count; i += 2)
            {
                dict[midMessagePairs[0]] = midMessagePairs[1];
            }
            
            [self _replaceMessagesWithNewMessages:dict];
        }];
    }
    else if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messagesDeleted", _peerId]])
    {
        [_queue dispatch:^
        {
            [self _deleteMessagesWithIds:((SGraphObjectNode *)resource).object];
        }];
    }
}

- (void)actorMessageReceived:(NSString *)path messageType:(NSString *)messageType message:(id)message
{
    if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/updateMediaHistory/(%" PRIx64 ")", _peerId]])
    {
        if ([messageType isEqualToString:@"messagesLoaded"])
        {
            [_queue dispatch:^
            {
                [self _addMessages:message];
            }];
        }
    }
}

- (void)actionStageActionRequested:(NSString *)action options:(NSDictionary *)options
{
    if ([action isEqualToString:@"willForwardMessages"])
    {
        UIViewController *controller = [[options objectForKey:@"controller"] navigationController];
        if (controller == nil)
            return;
        
        UIViewController *viewController = nil;
        if (self.viewControllerForModalPresentation)
            viewController = self.viewControllerForModalPresentation();
        
        if (viewController != nil)
        {   
            if (self.dismiss)
                self.dismiss(true, true);
        }
    }
}

@end

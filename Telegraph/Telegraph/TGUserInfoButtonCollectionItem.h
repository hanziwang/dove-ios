/*
 * This is the source code of Telegram for iOS v. 1.1
 * It is licensed under GNU GPL v. 2 or later.
 * You should have received a copy of the license in this archive (see LICENSE).
 *
 * Copyright Peter Iakovlev, 2013.
 */

#import "TGCollectionItem.h"

@interface TGUserInfoButtonCollectionItem : TGCollectionItem

@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIColor *titleColor;

- (instancetype)initWithTitle:(NSString *)title action:(SEL)action;

@end

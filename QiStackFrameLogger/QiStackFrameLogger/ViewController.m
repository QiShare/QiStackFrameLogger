//
//  ViewController.m
//  QiStackFrameLogger
//
//  Created by liusiqi on 2020/4/24.
//  Copyright © 2020 liusiqi. All rights reserved.
//

#import "ViewController.h"
#import "QiStackFrameLogger.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)foo {
    [self bar];
}

- (void)bar {
    while (true) {
        ;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        QiLOG_MAIN
    });
    [self foo];
}


@end

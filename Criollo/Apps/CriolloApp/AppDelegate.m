//
//  AppDelegate.m
//  CriolloApp
//
//  Created by Cătălin Stan on 23/03/16.
//  Copyright © 2016 Cătălin Stan. All rights reserved.
//

#import "AppDelegate.h"

#import "HelloWorldViewController.h"
#import "SystemInfoHelper.h"
#import "APIController.h"
#import "MultiRouteViewController.h"

#define PortNumber          10781
#define LogConnections          0
#define LogRequests             1

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate () <CRServerDelegate> {
    dispatch_queue_t backgroundQueue;
}

@property (nonatomic, strong) CRServer* server;

@end

NS_ASSUME_NONNULL_END

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    BOOL isFastCGI = [[NSUserDefaults standardUserDefaults] boolForKey:@"FastCGI"];
    Class serverClass = isFastCGI ? [CRFCGIServer class] : [CRHTTPServer class];
    self.server = [[serverClass alloc] initWithDelegate:self];

    if ( !isFastCGI ) {
        ((CRHTTPServer *)self.server).isSecure = YES;
        ((CRHTTPServer *)self.server).certificatePath = [[NSBundle mainBundle] pathForResource:@"cert" ofType:@"pem"];
        ((CRHTTPServer *)self.server).certificateKeyPath = [[NSBundle mainBundle] pathForResource:@"key" ofType:@"pem"];
    }

    backgroundQueue = dispatch_queue_create(self.className.UTF8String, DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(backgroundQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));

    NSString* bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSString* shortVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString* buildNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];

    // Add a header that says who we are :)
    [self.server add:^(CRRequest *request, CRResponse *response, CRRouteCompletionBlock completionHandler) {
        [response setValue:[NSString stringWithFormat:@"%@, %@ build %@", bundleIdentifier, shortVersion, buildNumber] forHTTPHeaderField:@"Server"];
        if ( ! request.cookies[@"session_cookie"] ) {
            [response setCookie:@"session_cookie" value:[NSUUID UUID].UUIDString path:@"/" expires:nil domain:nil secure:NO];
        }
        completionHandler();
    }];

    // Prints a simple hello world as text/plain
    CRRouteBlock helloBlock = ^(CRRequest *request, CRResponse *response, CRRouteCompletionBlock completionHandler ) {
        [response setValue:@"text/plain" forHTTPHeaderField:@"Content-type"];
        [response send:@"Hello World"];
        completionHandler();
    };
    [self.server add:@"/" block:helloBlock];

    // Prints a hello world JSON object as application/json
    CRRouteBlock jsonHelloBlock = ^(CRRequest *request, CRResponse *response, CRRouteCompletionBlock completionHandler ) {
        [response setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-type"];
        [response send:@{@"status":@(YES), @"mesage": @"Hello world"}];
        completionHandler();
    };
    [self.server add:@"/json" block:jsonHelloBlock];

    [self.server post:@"/post" block:^(CRRequest * _Nonnull request, CRResponse * _Nonnull response, CRRouteCompletionBlock  _Nonnull completionHandler) {
        [response setValue:@"text/plain" forHTTPHeaderField:@"Content-type"];
        [response sendString:[NSString stringWithFormat:@"%@\r\n\r\n--%@\r\n\r\n--", request, request.body]];
    }];

    // Serve static files from "/Public" (relative to bundle)
    NSString* staticFilesPath = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"Public"];
    [self.server mount:@"/static" directoryAtPath:staticFilesPath options:CRStaticDirectoryServingOptionsCacheFiles];

    // Redirecter
    [self.server get:@"/redirect" block:^(CRRequest * _Nonnull request, CRResponse * _Nonnull response, CRRouteCompletionBlock  _Nonnull completionHandler) {
        @autoreleasepool {
            NSURL* redirectURL = [NSURL URLWithString:(request.query[@"redirect"] ? : @"")];
            if ( redirectURL ) {
                [response redirectToURL:redirectURL];
            }
        }
    }];

    // Public
    [self.server mount:@"/pub" directoryAtPath:@"~" options:CRStaticDirectoryServingOptionsAutoIndex];

    // API
    [self.server add:@"/api" controller:[APIController class]];

    // Multiroute
    [self.server add:@"/multi" viewController:[MultiRouteViewController class] withNibName:@"MultiRouteViewController" bundle:nil];

    [self.server add:@"/mime" block:^(CRRequest * _Nonnull request, CRResponse * _Nonnull response, CRRouteCompletionBlock  _Nonnull completionHandler) {
        [response setValue:@"text/html; charset=utf=8" forHTTPHeaderField:@"Content-type"];
        [response write:@"<html>"];
        [response write:@"<head>"];
        [response write:@"<link rel=\"stylesheet\" href=\"/static/style.css\"/>"];
        [response write:@"</head>"];
        [response write:@"<body>"];
        [response write:@"<h2>Mime</h2>"];
        [response write:@"<form action=\"\" method=\"post\" enctype=\"multipart/form-data\">"];
        [response write:@"<input type=\"hidden\" name=\"MAX_FILE_SIZE\" value=\"67108864\" />"];
        [response write:@"<div><label>File: </label><input type=\"file\" name=\"file1\" /></div>"];
        [response write:@"<div><label>Text: </label><input type=\"text\" name=\"text1\" /></div>"];
        [response write:@"<div><label>Check: </label><input type=\"checkbox\" name=\"checkbox1\" value=\"1\" /></div>"];
        [response write:@"<div><input type=\"submit\"/></div>"];
        [response write:@"</form>"];

        if ( request.method == CRHTTPMethodPost ) {
            if ( request.body != nil ) {
                [response write:@"<h2>Request Body</h2>"];
                [response write:@"<pre>"];
                if ( [request.body isKindOfClass:[NSDictionary class]] ) {
                    [request.body enumerateKeysAndObjectsUsingBlock:^(NSString *  _Nonnull key, NSString *  _Nonnull obj, BOOL * _Nonnull stop) {
                        [response writeFormat:@"%@: %@\n", key, obj];
                    }];
                } else if ( [request.body isKindOfClass:[NSData class]] ) {
                    NSData * data = request.body;
                    [response writeString:[[NSString alloc] initWithBytesNoCopy:(void *)data.bytes length:data.length encoding:NSASCIIStringEncoding freeWhenDone:NO]];
                }
                [response write:@"</pre>"];
            }

            if ( request.files != nil ) {
                [response write:@"<h2>Request Files</h2>"];
                [response write:@"<pre>"];
                [request.files enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, CRUploadedFile * _Nonnull obj, BOOL * _Nonnull stop) {
                    [response writeFormat:@"%@: %@\n", key, @{@"name": obj.name ? : @"(null)", @"path": obj.temporaryFileURL ? : @"(null)", @"attributes": obj.attributes ? : @"(null)", @"mime": obj.mimeType ? : @"(null)" }];
                }];
                [response write:@"</pre>"];
            }
        }

        [response write:@"<hr/>"];
        [response write:@"<h2>Request Env</h2>"];
        [response write:@"<pre>"];
        [request.env enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSString * _Nonnull obj, BOOL * _Nonnull stop) {
            [response writeFormat:@"%@: %@\n", key, obj];
        }];
        [response write:@"</pre>"];

        [response write:@"</body>"];
        [response write:@"</html>"];
        [response finish];
        completionHandler();
    }];

    // Placeholder path controller
    [self.server add:@"/blog/:year/:month/:slug" viewController:[HelloWorldViewController class] withNibName:@"HelloWorldViewController" bundle:nil recursive:NO method:CRHTTPMethodAll];

    // Regex path controller
    [self.server add:@"/f[a-z]{2}/:payload" viewController:[HelloWorldViewController class] withNibName:@"HelloWorldViewController" bundle:nil recursive:NO method:CRHTTPMethodAll];

    // HTML view controller
    [self.server add:@"/controller" viewController:[HelloWorldViewController class] withNibName:@"HelloWorldViewController" bundle:nil];

    [self.server add:@"/posts/:pid" block:^(CRRequest * _Nonnull request, CRResponse * _Nonnull response, CRRouteCompletionBlock  _Nonnull completionHandler) {
        [response send:request.query];
    }];

    [self startServer];
}

- (CRApplicationTerminateReply)applicationShouldTerminate:(CRApplication *)sender {
    static CRApplicationTerminateReply reply;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reply = CRTerminateLater;
        [self.server closeAllConnections:^{
            reply = CRTerminateNow;
        }];
    });
    return reply;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self.server stopListening];
}

- (void)startServer {
    NSError *serverError;

    if ( [self.server startListening:&serverError portNumber:PortNumber] ) {

        // Get server ip address
        NSString* address = [SystemInfoHelper IPAddress];
        if ( !address ) {
            address = @"127.0.0.1";
        }

        // Set the base url. This is only for logging
        NSURL* baseURL = [NSURL URLWithString:[NSString stringWithFormat:@"http%@://%@:%d", ((CRHTTPServer *)self.server).isSecure ? @"s" : @"", address, PortNumber]];

        [CRApp logFormat:@"%@ Started HTTP server at %@", [NSDate date], baseURL.absoluteString];

        // Get the list of paths
        NSArray<NSString *> * routePaths = [self.server valueForKeyPath:@"routes.path"];
        NSMutableArray<NSURL *> *paths = [NSMutableArray array];
        [routePaths enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ( [obj isKindOfClass:[NSNull class]] ) {
                return;
            }
            [paths addObject:[baseURL URLByAppendingPathComponent:obj]];
        }];
        NSArray<NSURL*>* sortedPaths =[paths sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"absoluteString" ascending:YES]]];
        [CRApp logFormat:@"Available paths are:"];
        [sortedPaths enumerateObjectsUsingBlock:^(NSURL * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_async( backgroundQueue, ^{
                [CRApp logFormat:@" * %@", obj.absoluteString];
            });
        }];

    } else {
        [CRApp logErrorFormat:@"%@ Failed to start HTTP server. %@", [NSDate date], serverError.localizedDescription];
        [CRApp terminate:nil];
    }
}

#if LogConnections
- (void)server:(CRServer *)server didAcceptConnection:(CRConnection *)connection {
    NSString* remoteAddress = connection.remoteAddress.copy;
    NSUInteger remotePort = connection.remotePort;
    dispatch_async( backgroundQueue, ^{
        [CRApp logFormat:@"Accepted connection from %@:%d", remoteAddress, remotePort];
    });
}

- (void)server:(CRServer *)server didCloseConnection:(CRConnection *)connection {
    NSString* remoteAddress = connection.remoteAddress.copy;
    NSUInteger remotePort = connection.remotePort;
    dispatch_async( backgroundQueue, ^{
        [CRApp logFormat:@"Disconnected %@:%d", remoteAddress, remotePort];
    });
}
#endif

- (void)server:(CRServer *)server didFinishRequest:(CRRequest *)request {
#if LogRequests
    NSString* contentLength = [request.response valueForHTTPHeaderField:@"Content-Length"];
    NSString* userAgent = request.env[@"HTTP_USER_AGENT"];
    NSString* remoteAddress = request.env[@"HTTP_X_FORWARDED_FOR"].length > 0 ? request.env[@"HTTP_X_FORWARDED_FOR"] : request.env[@"REMOTE_ADDR"];
    NSUInteger statusCode = request.response.statusCode;
    dispatch_async( backgroundQueue, ^{
        [CRApp logFormat:@"%@ %@ %@ - %lu %@ - %@", [NSDate date], remoteAddress, request, statusCode, contentLength ? : @"-", userAgent];
    });
#endif
    [SystemInfoHelper addRequest];
}

@end

#import <Foundation/Foundation.h>
#import "MEGASdk.h"

NS_ASSUME_NONNULL_BEGIN

/// Engine settings and nodes that the Objective-C bindings do not expose.
@interface MEGASdk (MGBridge)

/// Makes an SDK instance with more worker threads for chunk encryption and MAC
/// calculation (the stock initializer always uses one). With `uploadThumbnails`, the
/// engine makes thumbnails and previews for uploaded photos, videos and PDFs.
+ (nullable MEGASdk *)mg_sdkWithUserAgent:(NSString *)userAgent
                                 basePath:(NSString *)basePath
                            workerThreads:(NSUInteger)workerThreads
                         uploadThumbnails:(BOOL)uploadThumbnails
    NS_SWIFT_NAME(makeSdk(userAgent:basePath:workerThreads:uploadThumbnails:));

@property (nonatomic, readonly, nullable) MEGANode *mg_vaultNode NS_SWIFT_NAME(vaultNode);
/// Bytes per second.
@property (nonatomic, readonly) NSInteger mg_currentDownloadSpeed NS_SWIFT_NAME(currentDownloadSpeed);
@property (nonatomic, readonly) NSInteger mg_currentUploadSpeed NS_SWIFT_NAME(currentUploadSpeed);

/// Bytes per second. 0 means no limit.
- (void)mg_setMaxDownloadSpeed:(long long)bytesPerSecond NS_SWIFT_NAME(setMaxDownloadSpeed(_:));
- (void)mg_setMaxUploadSpeed:(long long)bytesPerSecond NS_SWIFT_NAME(setMaxUploadSpeed(_:));

@end

@interface MEGATransfer (MGBridge)
/// The sync engine owns the transfer (two-way sync or backup).
@property (nonatomic, readonly) BOOL mg_isSyncTransfer NS_SWIFT_NAME(isSyncTransfer);
@end

typedef NS_ENUM(NSInteger, MGSyncType) {
    MGSyncTypeTwoWay = 3,
    MGSyncTypeBackup = 4,
};

typedef NS_ENUM(NSInteger, MGSyncRunState) {
    MGSyncRunStatePending = 0,
    MGSyncRunStateLoading = 1,
    MGSyncRunStateRunning = 2,
    MGSyncRunStateSuspended = 4,
    MGSyncRunStateDisabled = 5,
};

@interface MGSyncInfo : NSObject
@property (nonatomic, readonly) uint64_t backupId;
@property (nonatomic, readonly) uint64_t remoteHandle;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *localPath;
@property (nonatomic, readonly, copy) NSString *remotePath;
@property (nonatomic, readonly) MGSyncType type;
@property (nonatomic, readonly) MGSyncRunState runState;
@property (nonatomic, readonly) NSInteger error;
@property (nonatomic, readonly, copy) NSString *errorDescription;
@property (nonatomic, readonly) NSInteger warning;
@end

@interface MGSyncStats : NSObject
@property (nonatomic, readonly) uint64_t backupId;
@property (nonatomic, readonly) BOOL scanning;
@property (nonatomic, readonly) BOOL syncing;
@property (nonatomic, readonly) NSInteger folderCount;
@property (nonatomic, readonly) NSInteger fileCount;
@property (nonatomic, readonly) NSInteger uploadCount;
@property (nonatomic, readonly) NSInteger downloadCount;
@end

@interface MGSyncStall : NSObject
@property (nonatomic, readonly) NSInteger reason;
/// MegaSyncStall::SyncPathProblem codes of the local paths, then of the cloud paths.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *pathProblems;
@property (nonatomic, readonly, copy) NSArray<NSString *> *localPaths;
@property (nonatomic, readonly, copy) NSArray<NSString *> *cloudPaths;
@property (nonatomic, readonly) BOOL detectedCloudSide;
@end

@protocol MGSyncControllerDelegate <NSObject>
/// Called on the main queue when a sync is added, removed, or changes state.
- (void)syncControllerDidChangeSyncs;
/// Called on the main queue.
- (void)syncControllerDidUpdateStats:(MGSyncStats *)stats;
/// Called on the main queue when the global sync state (syncing, stalled) changes.
- (void)syncControllerDidChangeGlobalState;
@end

typedef void (^MGRequestCompletion)(NSInteger errorCode, NSString *_Nullable errorString);

/// Two-way syncs and backups (MEGA SDK sync engine).
@interface MGSyncController : NSObject

- (instancetype)initWithSdk:(MEGASdk *)sdk;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<MGSyncControllerDelegate> delegate;
/// Detaches the native listener; safe to call repeatedly before shutdown.
- (void)invalidate;
@property (nonatomic, readonly) NSArray<MGSyncInfo *> *syncs;
@property (nonatomic, readonly) BOOL isSyncing;
@property (nonatomic, readonly) BOOL isStalled;

/// For backups, the SDK makes the remote folder under Backups/<device name>.
- (void)addSyncOfType:(MGSyncType)type
            localPath:(NSString *)localPath
                 name:(nullable NSString *)name
         remoteHandle:(uint64_t)remoteHandle
           completion:(MGRequestCompletion)completion;
- (void)removeSync:(uint64_t)backupId completion:(MGRequestCompletion)completion;
- (void)setSync:(uint64_t)backupId running:(BOOL)running completion:(MGRequestCompletion)completion;
- (void)rescanSync:(uint64_t)backupId;
- (void)fetchStallsWithCompletion:(void (^)(NSArray<MGSyncStall *> *stalls))completion;

+ (NSString *)descriptionForSyncError:(NSInteger)error;

@end

/// Checks of the cryptography engine (Crypto++ as built for the SDK).
@interface MGDiagnostics : NSObject
/// YES when Crypto++ uses the ARMv8 AES instructions.
@property (class, nonatomic, readonly) BOOL hasHardwareAES;
/// AES-128-CTR throughput in MB/s (file content cipher of MEGA).
+ (double)aesCTRThroughputWithMegabytes:(NSUInteger)megabytes;
/// AES-128 CBC-MAC throughput in MB/s (chunk MAC of MEGA).
+ (double)cbcMACThroughputWithMegabytes:(NSUInteger)megabytes;
@end

NS_ASSUME_NONNULL_END

#import "MEGABridge.h"
#import "MEGASdk+init.h"
#import "MEGANode+init.h"
#import "MGGfxProcessor.h"
#import <objc/runtime.h>

#include "megaapi.h"
#include <chrono>
#include <cryptopp/aes.h>
#include <cryptopp/cpu.h>
#include <cryptopp/cbcmac.h>
#include <cryptopp/modes.h>
#include <memory>
#include <string>
#include <vector>

using namespace mega;

@interface MEGASdk (MGBridgePrivate)
- (void)setMegaApi:(nullable MegaApi *)megaApi;
@end

// Associated objects are released after MEGASdk's dealloc destroys the engine.
// Each engine gets its own mutable graphics processor; SDK graphics threads must
// never share a bitmap or output buffer with another engine.
@interface MGGraphicsOwner : NSObject {
@public
    std::unique_ptr<MGGfxProcessor> processor;
}
@end
@implementation MGGraphicsOwner
- (instancetype)init {
    if ((self = [super init])) processor = std::make_unique<MGGfxProcessor>();
    return self;
}
@end
static char graphicsOwnerKey;

namespace {

/// One-shot request listener that runs a block and deletes itself.
class BlockRequestListener final : public MegaRequestListener
{
public:
    explicit BlockRequestListener(void (^block)(MegaRequest *, MegaError *)) : mBlock([block copy]) {}

    void onRequestFinish(MegaApi *, MegaRequest *request, MegaError *error) override
    {
        mBlock(request, error);
        delete this;
    }

private:
    void (^mBlock)(MegaRequest *, MegaError *);
};

NSString *string(const char *value)
{
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

MegaRequestListener *completionListener(MGRequestCompletion completion)
{
    MGRequestCompletion done = [completion copy];
    return new BlockRequestListener(^(MegaRequest *request, MegaError *error) {
        NSInteger code = error->getErrorCode();
        int syncError = error->getSyncError();
        NSString *message = syncError != MegaSync::NO_SYNC_ERROR
            ? string(MegaSync::getMegaSyncErrorCode(syncError))
            : (code == MegaError::API_OK ? nil : string(error->getErrorString()));
        dispatch_async(dispatch_get_main_queue(), ^{
            done(code, message);
        });
    });
}

} // namespace

#pragma mark - MEGASdk (MGBridge)

@implementation MEGASdk (MGBridge)

+ (MEGASdk *)mg_sdkWithUserAgent:(NSString *)userAgent
                        basePath:(NSString *)basePath
                   workerThreads:(NSUInteger)workerThreads
                uploadThumbnails:(BOOL)uploadThumbnails
{
    MEGASdk *sdk = [[MEGASdk alloc] initWithAppKey:@"" userAgent:userAgent basePath:basePath];
    if (!sdk) return nil;

    // The bindings create the engine with one worker thread and no graphics provider.
    // Replace it before any listener or session is attached.
    std::unique_ptr<MegaGfxProvider> provider;
    if (uploadThumbnails)
    {
        // The engine keeps a raw pointer to the processor for its whole life.
        MGGraphicsOwner *owner = [[MGGraphicsOwner alloc] init];
        objc_setAssociatedObject(sdk, &graphicsOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        provider.reset(MegaGfxProvider::createExternalInstance(owner->processor.get()));
    }
    MegaApi *stock = [sdk getCPtr];
    [sdk setMegaApi:new MegaApi(nullptr,
                                provider.get(),
                                basePath.UTF8String,
                                userAgent.UTF8String,
                                (unsigned)MIN(MAX(workerThreads, 1), 8),
                                MegaApi::CLIENT_TYPE_DEFAULT)];
    delete stock;
    return sdk;
}

- (MEGANode *)mg_vaultNode
{
    MegaApi *api = [self getCPtr];
    MegaNode *node = api ? api->getVaultNode() : nullptr;
    return node ? [[MEGANode alloc] initWithMegaNode:node cMemoryOwn:YES] : nil;
}

- (NSInteger)mg_currentDownloadSpeed
{
    MegaApi *api = [self getCPtr];
    return api ? api->getCurrentDownloadSpeed() : 0;
}

- (NSInteger)mg_currentUploadSpeed
{
    MegaApi *api = [self getCPtr];
    return api ? api->getCurrentUploadSpeed() : 0;
}

- (void)mg_setMaxDownloadSpeed:(long long)bytesPerSecond
{
    if (MegaApi *api = [self getCPtr]) api->setMaxDownloadSpeed(bytesPerSecond);
}

- (void)mg_setMaxUploadSpeed:(long long)bytesPerSecond
{
    if (MegaApi *api = [self getCPtr]) api->setMaxUploadSpeed(bytesPerSecond);
}

@end

#pragma mark - Value objects

@implementation MGSyncInfo

- (instancetype)initWithSync:(const MegaSync *)sync
{
    if ((self = [super init]))
    {
        _backupId = sync->getBackupId();
        _remoteHandle = sync->getMegaHandle();
        _name = string(sync->getName());
        _localPath = string(sync->getLocalFolder());
        _remotePath = string(sync->getLastKnownMegaFolder());
        _type = (MGSyncType)sync->getType();
        _runState = (MGSyncRunState)sync->getRunState();
        _error = sync->getError();
        _errorDescription = _error ? string(MegaSync::getMegaSyncErrorCode(sync->getError())) : @"";
        _warning = sync->getWarning();
    }
    return self;
}

@end

@implementation MGSyncStats

- (instancetype)initWithStats:(const MegaSyncStats *)stats
{
    if ((self = [super init]))
    {
        _backupId = stats->getBackupId();
        _scanning = stats->isScanning();
        _syncing = stats->isSyncing();
        _folderCount = stats->getFolderCount();
        _fileCount = stats->getFileCount();
        _uploadCount = stats->getUploadCount();
        _downloadCount = stats->getDownloadCount();
    }
    return self;
}

@end

@implementation MGSyncStall

- (instancetype)initWithStall:(const MegaSyncStall *)stall
{
    if ((self = [super init]))
    {
        _reason = stall->reason();
        _reasonDescription = string(stall->reasonDebugString());
        NSMutableArray *local = [NSMutableArray array];
        for (unsigned i = 0; i < stall->pathCount(false); i++) [local addObject:string(stall->path(false, (int)i))];
        NSMutableArray *cloud = [NSMutableArray array];
        for (unsigned i = 0; i < stall->pathCount(true); i++) [cloud addObject:string(stall->path(true, (int)i))];
        _localPaths = local;
        _cloudPaths = cloud;
        _detectedCloudSide = stall->detectedCloudSide();
    }
    return self;
}

@end

#pragma mark - MGSyncController

@class MGSyncController;

namespace {

/// Forwards the sync callbacks to the controller delegate on the main queue.
/// The SDK sends many other events to a MegaListener; the defaults ignore them.
class SyncListener final : public MegaListener
{
public:
    explicit SyncListener(MGSyncController *controller) : mController(controller) {}

    void onSyncAdded(MegaApi *, MegaSync *) override { syncsChanged(); }
    void onSyncDeleted(MegaApi *, MegaSync *) override { syncsChanged(); }
    void onSyncStateChanged(MegaApi *, MegaSync *) override { syncsChanged(); }
    void onSyncRemoteRootChanged(MegaApi *, MegaSync *) override { syncsChanged(); }

    void onSyncStatsUpdated(MegaApi *, MegaSyncStats *stats) override
    {
        MGSyncStats *value = [[MGSyncStats alloc] initWithStats:stats];
        __weak MGSyncController *controller = mController;
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller.delegate syncControllerDidUpdateStats:value];
        });
    }

    void onGlobalSyncStateChanged(MegaApi *) override
    {
        __weak MGSyncController *controller = mController;
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller.delegate syncControllerDidChangeGlobalState];
        });
    }

private:
    void syncsChanged()
    {
        __weak MGSyncController *controller = mController;
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller.delegate syncControllerDidChangeSyncs];
        });
    }

    __weak MGSyncController *mController;
};

} // namespace

@implementation MGSyncController
{
    MEGASdk *_sdk;
    std::unique_ptr<SyncListener> _listener;
}

- (instancetype)initWithSdk:(MEGASdk *)sdk
{
    if ((self = [super init]))
    {
        _sdk = sdk;
        _listener = std::make_unique<SyncListener>(self);
        if (MegaApi *api = [sdk getCPtr]) api->addListener(_listener.get());
    }
    return self;
}

- (void)invalidate
{
    self.delegate = nil;
    if (_listener) {
        if (MegaApi *api = [_sdk getCPtr]) api->removeListener(_listener.get());
        _listener.reset();
    }
}

- (void)dealloc
{
    [self invalidate];
}

- (NSArray<MGSyncInfo *> *)syncs
{
    MegaApi *api = [_sdk getCPtr];
    if (!api) return @[];
    std::unique_ptr<MegaSyncList> list(api->getSyncs());
    if (!list) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:list->size()];
    for (int i = 0; i < list->size(); i++)
    {
        [result addObject:[[MGSyncInfo alloc] initWithSync:list->get(i)]];
    }
    return result;
}

- (BOOL)isSyncing
{
    MegaApi *api = [_sdk getCPtr];
    return api ? api->isSyncing() : NO;
}

- (BOOL)isStalled
{
    MegaApi *api = [_sdk getCPtr];
    return api ? api->isSyncStalled() : NO;
}

- (void)addSyncOfType:(MGSyncType)type
            localPath:(NSString *)localPath
                 name:(NSString *)name
         remoteHandle:(uint64_t)remoteHandle
           completion:(MGRequestCompletion)completion
{
    MegaApi *api = [_sdk getCPtr];
    if (!api) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(MegaError::API_EINTERNAL, @"The engine is unavailable."); });
        return;
    }
    MEGASdk *retainedSdk = _sdk;
    MGRequestCompletion done = ^(NSInteger code, NSString *message) {
        (void)[retainedSdk getCPtr];
        completion(code, message);
    };
    std::string local(localPath.fileSystemRepresentation);
    std::string label = name.length ? std::string(name.UTF8String) : std::string();

    void (^startSync)(void) = ^{
        api->syncFolder((MegaSync::SyncType)type,
                        local,
                        label,
                        type == MGSyncTypeBackup ? INVALID_HANDLE : remoteHandle,
                        std::string(),
                        completionListener(done));
    };

    // Backups go to Backups/<device name>/<folder>. The account needs the
    // "My backups" folder attribute first, as in the official clients.
    void (^prepareBackups)(void) = ^{
        if (type != MGSyncTypeBackup)
        {
            startSync();
            return;
        }
        api->getUserAttribute(MegaApi::USER_ATTR_MY_BACKUPS_FOLDER, new BlockRequestListener(^(MegaRequest *, MegaError *error) {
            if (error->getErrorCode() == MegaError::API_OK) { startSync(); return; }
            if (error->getErrorCode() != MegaError::API_ENOENT) {
                NSInteger code = error->getErrorCode();
                NSString *message = string(error->getErrorString());
                dispatch_async(dispatch_get_main_queue(), ^{ done(code, message); });
                return;
            }
            api->setMyBackupsFolder("My backups", new BlockRequestListener(^(MegaRequest *, MegaError *setError) {
                if (setError->getErrorCode() == MegaError::API_OK)
                {
                    startSync();
                }
                else
                {
                    NSString *message = string(setError->getErrorString());
                    NSInteger code = setError->getErrorCode();
                    dispatch_async(dispatch_get_main_queue(), ^{ done(code, message); });
                }
            }));
        }));
    };

    // Syncs and backups need a device name.
    api->getDeviceName(nullptr, new BlockRequestListener(^(MegaRequest *, MegaError *error) {
        if (error->getErrorCode() == MegaError::API_OK) { prepareBackups(); return; }
        if (error->getErrorCode() != MegaError::API_ENOENT) {
            NSInteger code = error->getErrorCode();
            NSString *message = string(error->getErrorString());
            dispatch_async(dispatch_get_main_queue(), ^{ done(code, message); });
            return;
        }
        NSString *deviceName = NSHost.currentHost.localizedName ?: @"Mac";
        api->setDeviceName(nullptr, deviceName.UTF8String, new BlockRequestListener(^(MegaRequest *, MegaError *error) {
            if (error->getErrorCode() == MegaError::API_OK) { prepareBackups(); return; }
            NSInteger code = error->getErrorCode();
            NSString *message = string(error->getErrorString());
            dispatch_async(dispatch_get_main_queue(), ^{ done(code, message); });
        }));
    }));
}

- (void)removeSync:(uint64_t)backupId completion:(MGRequestCompletion)completion
{
    if (MegaApi *api = [_sdk getCPtr]) api->removeSync(backupId, completionListener(completion));
    else dispatch_async(dispatch_get_main_queue(), ^{ completion(MegaError::API_EINTERNAL, @"The engine is unavailable."); });
}

- (void)setSync:(uint64_t)backupId running:(BOOL)running completion:(MGRequestCompletion)completion
{
    if (MegaApi *api = [_sdk getCPtr])
    {
        api->setSyncRunState(backupId,
                             running ? MegaSync::RUNSTATE_RUNNING : MegaSync::RUNSTATE_SUSPENDED,
                             completionListener(completion));
    }
    else dispatch_async(dispatch_get_main_queue(), ^{ completion(MegaError::API_EINTERNAL, @"The engine is unavailable."); });
}

- (void)rescanSync:(uint64_t)backupId
{
    if (MegaApi *api = [_sdk getCPtr]) api->rescanSync(backupId, false);
}

- (void)fetchStallsWithCompletion:(void (^)(NSArray<MGSyncStall *> *))completion
{
    MegaApi *api = [_sdk getCPtr];
    if (!api) { dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    void (^done)(NSArray<MGSyncStall *> *) = [completion copy];
    api->getMegaSyncStallList(new BlockRequestListener(^(MegaRequest *request, MegaError *) {
        NSMutableArray *stalls = [NSMutableArray array];
        if (MegaSyncStallList *list = request->getMegaSyncStallList())
        {
            for (size_t i = 0; i < list->size(); i++)
            {
                [stalls addObject:[[MGSyncStall alloc] initWithStall:list->get(i)]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(stalls);
        });
    }));
}

+ (NSString *)descriptionForSyncError:(NSInteger)error
{
    return string(MegaSync::getMegaSyncErrorCode((int)error));
}

@end

#pragma mark - MGDiagnostics

@implementation MGDiagnostics

+ (BOOL)hasHardwareAES
{
    return CryptoPP::HasAES();
}

+ (double)aesCTRThroughputWithMegabytes:(NSUInteger)megabytes
{
    std::vector<CryptoPP::byte> key(16, 0x42), iv(16, 0x24), buffer(1 << 20, 0x5a);
    CryptoPP::CTR_Mode<CryptoPP::AES>::Encryption cipher(key.data(), key.size(), iv.data());
    auto start = std::chrono::steady_clock::now();
    for (NSUInteger i = 0; i < megabytes; i++)
    {
        cipher.ProcessData(buffer.data(), buffer.data(), buffer.size());
    }
    std::chrono::duration<double> elapsed = std::chrono::steady_clock::now() - start;
    return megabytes / elapsed.count();
}

+ (double)cbcMACThroughputWithMegabytes:(NSUInteger)megabytes
{
    std::vector<CryptoPP::byte> key(16, 0x42), buffer(1 << 20, 0x5a), digest(16);
    CryptoPP::CBC_MAC<CryptoPP::AES> mac(key.data(), key.size());
    auto start = std::chrono::steady_clock::now();
    for (NSUInteger i = 0; i < megabytes; i++)
    {
        mac.Update(buffer.data(), buffer.size());
    }
    mac.Final(digest.data());
    std::chrono::duration<double> elapsed = std::chrono::steady_clock::now() - start;
    return megabytes / elapsed.count();
}

@end

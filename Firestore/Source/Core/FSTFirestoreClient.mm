/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Core/FSTFirestoreClient.h"

#include <chrono>  // NOLINT(build/c++11)
#include <future>  // NOLINT(build/c++11)
#include <memory>
#include <utility>

#import "FIRFirestoreErrors.h"
#import "FIRFirestoreSettings.h"
#import "Firestore/Source/API/FIRDocumentReference+Internal.h"
#import "Firestore/Source/API/FIRDocumentSnapshot+Internal.h"
#import "Firestore/Source/API/FIRQuery+Internal.h"
#import "Firestore/Source/API/FIRQuerySnapshot+Internal.h"
#import "Firestore/Source/API/FIRSnapshotMetadata+Internal.h"
#import "Firestore/Source/Core/FSTEventManager.h"
#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Core/FSTSyncEngine.h"
#import "Firestore/Source/Core/FSTTransaction.h"
#import "Firestore/Source/Core/FSTView.h"
#import "Firestore/Source/Local/FSTLRUGarbageCollector.h"
#import "Firestore/Source/Local/FSTLevelDB.h"
#import "Firestore/Source/Local/FSTLocalSerializer.h"
#import "Firestore/Source/Local/FSTLocalStore.h"
#import "Firestore/Source/Local/FSTMemoryPersistence.h"
#import "Firestore/Source/Model/FSTDocument.h"
#import "Firestore/Source/Model/FSTDocumentSet.h"
#import "Firestore/Source/Remote/FSTRemoteStore.h"
#import "Firestore/Source/Remote/FSTSerializerBeta.h"
#import "Firestore/Source/Util/FSTClasses.h"

#include "Firestore/core/src/firebase/firestore/auth/credentials_provider.h"
#include "Firestore/core/src/firebase/firestore/core/database_info.h"
#include "Firestore/core/src/firebase/firestore/model/database_id.h"
#include "Firestore/core/src/firebase/firestore/remote/datastore.h"
#include "Firestore/core/src/firebase/firestore/util/async_queue.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"

namespace util = firebase::firestore::util;
using firebase::firestore::auth::CredentialsProvider;
using firebase::firestore::auth::User;
using firebase::firestore::core::DatabaseInfo;
using firebase::firestore::local::LruParams;
using firebase::firestore::model::DatabaseId;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::DocumentMap;
using firebase::firestore::model::MaybeDocumentMap;
using firebase::firestore::model::OnlineState;
using firebase::firestore::remote::Datastore;
using firebase::firestore::util::Path;
using firebase::firestore::util::Status;
using firebase::firestore::util::AsyncQueue;
using firebase::firestore::util::DelayedOperation;
using firebase::firestore::util::Executor;
using firebase::firestore::util::TimerId;

NS_ASSUME_NONNULL_BEGIN

/** How long we wait to try running LRU GC after SDK initialization. */
static const std::chrono::milliseconds FSTLruGcInitialDelay = std::chrono::minutes(1);
/** Minimum amount of time between GC checks, after the first one. */
static const std::chrono::milliseconds FSTLruGcRegularDelay = std::chrono::minutes(5);

@interface FSTFirestoreClient () {
  DatabaseInfo _databaseInfo;
}

- (instancetype)initWithDatabaseInfo:(const DatabaseInfo &)databaseInfo
                            settings:(FIRFirestoreSettings *)settings
                 credentialsProvider:
                     (CredentialsProvider *)credentialsProvider  // no passing ownership
                        userExecutor:(std::unique_ptr<Executor>)userExecutor
                         workerQueue:(std::unique_ptr<AsyncQueue>)queue NS_DESIGNATED_INITIALIZER;

@property(nonatomic, assign, readonly) const DatabaseInfo *databaseInfo;
@property(nonatomic, strong, readonly) FSTEventManager *eventManager;
@property(nonatomic, strong, readonly) id<FSTPersistence> persistence;
@property(nonatomic, strong, readonly) FSTSyncEngine *syncEngine;
@property(nonatomic, strong, readonly) FSTRemoteStore *remoteStore;
@property(nonatomic, strong, readonly) FSTLocalStore *localStore;

// Does not own the CredentialsProvider instance.
@property(nonatomic, assign, readonly) CredentialsProvider *credentialsProvider;

@end

@implementation FSTFirestoreClient {
  /**
   * Async queue responsible for all of our internal processing. When we get incoming work from
   * the user (via public API) or the network (incoming gRPC messages), we should always dispatch
   * onto this queue. This ensures our internal data structures are never accessed from multiple
   * threads simultaneously.
   */
  std::unique_ptr<AsyncQueue> _workerQueue;

  std::unique_ptr<Executor> _userExecutor;
  std::chrono::milliseconds _initialGcDelay;
  std::chrono::milliseconds _regularGcDelay;
  BOOL _gcHasRun;
  _Nullable id<FSTLRUDelegate> _lruDelegate;
  DelayedOperation _lruCallback;
}

- (Executor *)userExecutor {
  return _userExecutor.get();
}

- (AsyncQueue *)workerQueue {
  return _workerQueue.get();
}

+ (instancetype)clientWithDatabaseInfo:(const DatabaseInfo &)databaseInfo
                              settings:(FIRFirestoreSettings *)settings
                   credentialsProvider:
                       (CredentialsProvider *)credentialsProvider  // no passing ownership
                          userExecutor:(std::unique_ptr<Executor>)userExecutor
                           workerQueue:(std::unique_ptr<AsyncQueue>)workerQueue {
  return [[FSTFirestoreClient alloc] initWithDatabaseInfo:databaseInfo
                                                 settings:settings
                                      credentialsProvider:credentialsProvider
                                             userExecutor:std::move(userExecutor)
                                              workerQueue:std::move(workerQueue)];
}

- (instancetype)initWithDatabaseInfo:(const DatabaseInfo &)databaseInfo
                            settings:(FIRFirestoreSettings *)settings
                 credentialsProvider:
                     (CredentialsProvider *)credentialsProvider  // no passing ownership
                        userExecutor:(std::unique_ptr<Executor>)userExecutor
                         workerQueue:(std::unique_ptr<AsyncQueue>)workerQueue {
  if (self = [super init]) {
    _databaseInfo = databaseInfo;
    _credentialsProvider = credentialsProvider;
    _userExecutor = std::move(userExecutor);
    _workerQueue = std::move(workerQueue);
    _gcHasRun = NO;
    _initialGcDelay = FSTLruGcInitialDelay;
    _regularGcDelay = FSTLruGcRegularDelay;

    auto userPromise = std::make_shared<std::promise<User>>();
    bool initialized = false;

    __weak __typeof__(self) weakSelf = self;
    auto credentialChangeListener = [initialized, userPromise, weakSelf](User user) mutable {
      __typeof__(self) strongSelf = weakSelf;
      if (!strongSelf) return;

      if (!initialized) {
        initialized = true;
        userPromise->set_value(user);
      } else {
        strongSelf->_workerQueue->Enqueue(
            [strongSelf, user] { [strongSelf credentialDidChangeWithUser:user]; });
      }
    };

    _credentialsProvider->SetCredentialChangeListener(credentialChangeListener);

    // Defer initialization until we get the current user from the credentialChangeListener. This is
    // guaranteed to be synchronously dispatched onto our worker queue, so we will be initialized
    // before any subsequently queued work runs.
    _workerQueue->Enqueue([self, userPromise, settings] {
      User user = userPromise->get_future().get();
      [self initializeWithUser:user settings:settings];
    });
  }
  return self;
}

- (void)initializeWithUser:(const User &)user settings:(FIRFirestoreSettings *)settings {
  // Do all of our initialization on our own dispatch queue.
  _workerQueue->VerifyIsCurrentQueue();
  LOG_DEBUG("Initializing. Current user: %s", user.uid());

  // Note: The initialization work must all be synchronous (we can't dispatch more work) since
  // external write/listen operations could get queued to run before that subsequent work
  // completes.
  if (settings.isPersistenceEnabled) {
    Path dir = [FSTLevelDB storageDirectoryForDatabaseInfo:*self.databaseInfo
                                        documentsDirectory:[FSTLevelDB documentsDirectory]];

    FSTSerializerBeta *remoteSerializer =
        [[FSTSerializerBeta alloc] initWithDatabaseID:&self.databaseInfo->database_id()];
    FSTLocalSerializer *serializer =
        [[FSTLocalSerializer alloc] initWithRemoteSerializer:remoteSerializer];
    FSTLevelDB *ldb;
    Status levelDbStatus =
        [FSTLevelDB dbWithDirectory:std::move(dir)
                         serializer:serializer
                          lruParams:LruParams::WithCacheSize(settings.cacheSizeBytes)
                                ptr:&ldb];
    if (!levelDbStatus.ok()) {
      // If leveldb fails to start then just throw up our hands: the error is unrecoverable.
      // There's nothing an end-user can do and nearly all failures indicate the developer is doing
      // something grossly wrong so we should stop them cold in their tracks with a failure they
      // can't ignore.
      [NSException raise:NSInternalInconsistencyException
                  format:@"Failed to open DB: %s", levelDbStatus.ToString().c_str()];
    }
    _lruDelegate = ldb.referenceDelegate;
    _persistence = ldb;
    [self scheduleLruGarbageCollection];
  } else {
    _persistence = [FSTMemoryPersistence persistenceWithEagerGC];
  }

  _localStore = [[FSTLocalStore alloc] initWithPersistence:_persistence initialUser:user];

  auto datastore =
      std::make_shared<Datastore>(*self.databaseInfo, _workerQueue.get(), _credentialsProvider);

  _remoteStore = [[FSTRemoteStore alloc] initWithLocalStore:_localStore
                                                  datastore:std::move(datastore)
                                                workerQueue:_workerQueue.get()
                                         onlineStateHandler:[self](OnlineState onlineState) {
                                           [self.syncEngine applyChangedOnlineState:onlineState];
                                         }];

  _syncEngine = [[FSTSyncEngine alloc] initWithLocalStore:_localStore
                                              remoteStore:_remoteStore
                                              initialUser:user];

  _eventManager = [FSTEventManager eventManagerWithSyncEngine:_syncEngine];

  // Setup wiring for remote store.
  [_remoteStore setSyncEngine:_syncEngine];

  // NOTE: RemoteStore depends on LocalStore (for persisting stream tokens, refilling mutation
  // queue, etc.) so must be started after LocalStore.
  [_localStore start];
  [_remoteStore start];
}

/**
 * Schedules a callback to try running LRU garbage collection. Reschedules itself after the GC has
 * run.
 */
- (void)scheduleLruGarbageCollection {
  std::chrono::milliseconds delay = _gcHasRun ? _regularGcDelay : _initialGcDelay;
  _lruCallback = _workerQueue->EnqueueAfterDelay(delay, TimerId::GarbageCollectionDelay, [self]() {
    [self->_localStore collectGarbage:self->_lruDelegate.gc];
    self->_gcHasRun = YES;
    [self scheduleLruGarbageCollection];
  });
}

- (void)credentialDidChangeWithUser:(const User &)user {
  _workerQueue->VerifyIsCurrentQueue();

  LOG_DEBUG("Credential Changed. Current user: %s", user.uid());
  [self.syncEngine credentialDidChangeWithUser:user];
}

- (void)disableNetworkWithCompletion:(nullable FSTVoidErrorBlock)completion {
  _workerQueue->Enqueue([self, completion] {
    [self.remoteStore disableNetwork];
    if (completion) {
      self->_userExecutor->Execute([=] { completion(nil); });
    }
  });
}

- (void)enableNetworkWithCompletion:(nullable FSTVoidErrorBlock)completion {
  _workerQueue->Enqueue([self, completion] {
    [self.remoteStore enableNetwork];
    if (completion) {
      self->_userExecutor->Execute([=] { completion(nil); });
    }
  });
}

- (void)shutdownWithCompletion:(nullable FSTVoidErrorBlock)completion {
  _workerQueue->Enqueue([self, completion] {
    self->_credentialsProvider->SetCredentialChangeListener(nullptr);

    // If we've scheduled LRU garbage collection, cancel it.
    if (self->_lruCallback) {
      self->_lruCallback.Cancel();
    }
    [self.remoteStore shutdown];
    [self.persistence shutdown];
    if (completion) {
      self->_userExecutor->Execute([=] { completion(nil); });
    }
  });
}

- (FSTQueryListener *)listenToQuery:(FSTQuery *)query
                            options:(FSTListenOptions *)options
                viewSnapshotHandler:(FSTViewSnapshotHandler)viewSnapshotHandler {
  FSTQueryListener *listener = [[FSTQueryListener alloc] initWithQuery:query
                                                               options:options
                                                   viewSnapshotHandler:viewSnapshotHandler];

  _workerQueue->Enqueue([self, listener] { [self.eventManager addListener:listener]; });

  return listener;
}

- (void)removeListener:(FSTQueryListener *)listener {
  _workerQueue->Enqueue([self, listener] { [self.eventManager removeListener:listener]; });
}

- (void)getDocumentFromLocalCache:(FIRDocumentReference *)doc
                       completion:(void (^)(FIRDocumentSnapshot *_Nullable document,
                                            NSError *_Nullable error))completion {
  _workerQueue->Enqueue([self, doc, completion] {
    FSTMaybeDocument *maybeDoc = [self.localStore readDocument:doc.key];
    FIRDocumentSnapshot *_Nullable result = nil;
    NSError *_Nullable error = nil;

    if ([maybeDoc isKindOfClass:[FSTDocument class]]) {
      FSTDocument *document = (FSTDocument *)maybeDoc;
      result = [FIRDocumentSnapshot snapshotWithFirestore:doc.firestore
                                              documentKey:doc.key
                                                 document:document
                                                fromCache:YES
                                         hasPendingWrites:document.hasLocalMutations];
    } else if ([maybeDoc isKindOfClass:[FSTDeletedDocument class]]) {
      result = [FIRDocumentSnapshot snapshotWithFirestore:doc.firestore
                                              documentKey:doc.key
                                                 document:nil
                                                fromCache:YES
                                         hasPendingWrites:NO];
    } else {
      error = [NSError errorWithDomain:FIRFirestoreErrorDomain
                                  code:FIRFirestoreErrorCodeUnavailable
                              userInfo:@{
                                NSLocalizedDescriptionKey :
                                    @"Failed to get document from cache. (However, this document "
                                    @"may exist on the server. Run again without setting source to "
                                    @"FIRFirestoreSourceCache to attempt to retrieve the document "
                                    @"from the server.)",
                              }];
    }

    if (completion) {
      self->_userExecutor->Execute([=] { completion(result, error); });
    }
  });
}

- (void)getDocumentsFromLocalCache:(FIRQuery *)query
                        completion:(void (^)(FIRQuerySnapshot *_Nullable query,
                                             NSError *_Nullable error))completion {
  _workerQueue->Enqueue([self, query, completion] {
    DocumentMap docs = [self.localStore executeQuery:query.query];

    FSTView *view = [[FSTView alloc] initWithQuery:query.query remoteDocuments:DocumentKeySet{}];
    FSTViewDocumentChanges *viewDocChanges =
        [view computeChangesWithDocuments:docs.underlying_map()];
    FSTViewChange *viewChange = [view applyChangesToDocuments:viewDocChanges];
    HARD_ASSERT(viewChange.limboChanges.count == 0,
                "View returned limbo documents during local-only query execution.");

    FSTViewSnapshot *snapshot = viewChange.snapshot;
    FIRSnapshotMetadata *metadata =
        [FIRSnapshotMetadata snapshotMetadataWithPendingWrites:snapshot.hasPendingWrites
                                                     fromCache:snapshot.fromCache];

    FIRQuerySnapshot *result = [FIRQuerySnapshot snapshotWithFirestore:query.firestore
                                                         originalQuery:query.query
                                                              snapshot:snapshot
                                                              metadata:metadata];

    if (completion) {
      self->_userExecutor->Execute([=] { completion(result, nil); });
    }
  });
}

- (void)writeMutations:(NSArray<FSTMutation *> *)mutations
            completion:(nullable FSTVoidErrorBlock)completion {
  _workerQueue->Enqueue([self, mutations, completion] {
    if (mutations.count == 0) {
      if (completion) {
        self->_userExecutor->Execute([=] { completion(nil); });
      }
    } else {
      [self.syncEngine writeMutations:mutations
                           completion:^(NSError *error) {
                             // Dispatch the result back onto the user dispatch queue.
                             if (completion) {
                               self->_userExecutor->Execute([=] { completion(error); });
                             }
                           }];
    }
  });
};

- (void)transactionWithRetries:(int)retries
                   updateBlock:(FSTTransactionBlock)updateBlock
                    completion:(FSTVoidIDErrorBlock)completion {
  _workerQueue->Enqueue([self, retries, updateBlock, completion] {
    [self.syncEngine
        transactionWithRetries:retries
                   workerQueue:_workerQueue.get()
                   updateBlock:updateBlock
                    completion:^(id _Nullable result, NSError *_Nullable error) {
                      // Dispatch the result back onto the user dispatch queue.
                      if (completion) {
                        self->_userExecutor->Execute([=] { completion(result, error); });
                      }
                    }];
  });
}

- (const DatabaseInfo *)databaseInfo {
  return &_databaseInfo;
}

- (const DatabaseId *)databaseID {
  return &_databaseInfo.database_id();
}

@end

NS_ASSUME_NONNULL_END

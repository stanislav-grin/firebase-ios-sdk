/*
 * Copyright 2019 Google
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

#include "Firestore/core/src/firebase/firestore/remote/remote_store.h"

#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"

namespace firebase {
namespace firestore {
namespace remote {

void RemoteStore::StartWatchStream() {
  HARD_ASSERT(ShouldStartWatchStream(),
              "StartWatchStream called when ShouldStartWatchStream: is false.");
  watch_change_aggregator_ = absl::make_unique<WatchChangeAggregator>(this);
  watch_stream_->Start();

  online_state_tracker_.HandleWatchStreamStart();
}

void RemoteStore::ListenToTarget(FSTQueryData* query_data) {
  TargetId targetKey = query_data.target_id;
  HARD_ASSERT(listen_targets_.find(targetKey) == listen_targets_.end(),
              "listenToQuery called with duplicate target id: %s", targetKey);

  listen_targets_[targetKey] = query_data;

  if (ShouldStartWatchStream()) {
    StartWatchStream();
  } else if (watch_stream_->IsOpen()) {
    SendWatchRequest(query_data);
  }
}

void RemoteStore::SendWatchRequest(FSTQueryData* query_data) {
  watch_change_aggregator_->RecordPendingTargetRequest(query_data.target_id);
  watch_stream_->WatchQuery(query_data);
}

void RemoteStore::StopListening(TargetId target_id) {
  size_t num_erased = listen_targets_.erase(target_id);
  HARD_ASSERT(num_erased == 1,
              "stopListeningToTargetID: target not currently watched: %s",
              target_id);

  if (watch_stream_->IsOpen()) {
    SendUnwatchRequest(target_id);
  }
  if (listen_targets_.empty()) {
    if (watch_stream_->IsOpen()) {
      watch_stream_->MarkIdle();
    } else if (CanUseNetwork()) {
      // Revert to OnlineState::Unknown if the watch stream is not open and we
      // have no listeners, since without any listens to send we cannot confirm
      // if the stream is healthy and upgrade to OnlineState::Online.
      online_state_tracker_.UpdateState(OnlineState::Unknown);
    }
  }
}

void RemoteStore::SendUnwatchRequest(TargetId target_id) {
  watch_change_aggregator_->RecordPendingTargetRequest(target_id);
  watch_stream_->UnwatchTargetId(target_id);
}

bool RemoteStore::ShouldStartWatchStream() const {
  return CanUseNetwork() && !watch_stream_->IsStarted() &&
         !listen_targets_.empty();
}

void RemoteStore::CleanUpWatchStreamState() {
  watch_change_aggregator_.reset();
}

void RemoteStore::OnWatchStreamOpen() {
  // Restore any existing watches.
  for (const auto& kv : listen_targets_) {
    SendWatchRequest(kv.second);
  }
}

void RemoteStore::OnWatchStreamChange(const WatchChange& change,
                                      const SnapshotVersion& snapshot_version) {
  // Mark the connection as Online because we got a message from the server.
  online_state_tracker_.UpdateState(OnlineState::Online);

  if (change.type() == WatchChange::Type::TargetChange) {
    const WatchTargetChange& watch_target_change =
        static_cast<const WatchTargetChange&>(change);
    if (watch_target_change.state() == WatchTargetChangeState::Removed &&
        !watch_target_change.cause().ok()) {
      // There was an error on a target, don't wait for a consistent snapshot to
      // raise events
      return ProcessTargetError(watch_target_change);
    } else {
      watch_change_aggregator_->HandleTargetChange(watch_target_change);
    }
  } else if (change.type() == WatchChange::Type::Document) {
    watch_change_aggregator_->HandleDocumentChange(
        static_cast<const DocumentWatchChange&>(change));
  } else {
    HARD_ASSERT(
        change.type() == WatchChange::Type::ExistenceFilter,
        "Expected watchChange to be an instance of ExistenceFilterWatchChange");
    watch_change_aggregator_->HandleExistenceFilter(
        static_cast<const ExistenceFilterWatchChange&>(change));
  }

  if (snapshot_version != SnapshotVersion::None() &&
      snapshot_version >= [local_store_ lastRemoteSnapshotVersion]) {
    // We have received a target change with a global snapshot if the snapshot
    // version is not equal to SnapshotVersion.None().
    RaiseWatchSnapshot(snapshot_version);
  }
}

void RemoteStore::OnWatchStreamError(const Status& error) {
  if (error.ok()) {
    // Graceful stop (due to Stop() or idle timeout). Make sure that's
    // desirable.
    HARD_ASSERT(!ShouldStartWatchStream(),
                "Watch stream was stopped gracefully while still needed.");
  }

  CleanUpWatchStreamState();

  // If we still need the watch stream, retry the connection.
  if (ShouldStartWatchStream()) {
    online_state_tracker_.HandleWatchStreamFailure(error);

    StartWatchStream();
  } else {
    // We don't need to restart the watch stream because there are no active
    // targets. The online state is set to unknown because there is no active
    // attempt at establishing a connection.
    online_state_tracker_.UpdateState(OnlineState::Unknown);
  }
}

void RemoteStore::RaiseWatchSnapshot(const SnapshotVersion& snapshot_version) {
  HARD_ASSERT(snapshot_version != SnapshotVersion::None(),
              "Can't raise event for unknown SnapshotVersion");

  RemoteEvent remote_event =
      watch_change_aggregator_->CreateRemoteEvent(snapshot_version);

  // Update in-memory resume tokens. `FSTLocalStore` will update the persistent
  // view of these when applying the completed `RemoteEvent`.
  for (const auto& entry : remote_event.target_changes()) {
    const TargetChange& target_change = entry.second;
    NSData* resumeToken = target_change.resume_token();
    if (resumeToken.length > 0) {
      TargetId target_id = entry.first;
      auto found = listen_targets_.find(target_id);
      FSTQueryData* query_data =
          found != listen_targets_.end() ? found->second : nil;
      // A watched target might have been removed already.
      if (query_data) {
        listen_targets_[target_id] = [query_data
            query_dataByReplacingSnapshotVersion:snapshot_version
                                     resumeToken:resumeToken
                                  sequenceNumber:query_data.sequenceNumber];
      }
    }
  }

  // Re-establish listens for the targets that have been invalidated by
  // existence filter mismatches.
  for (TargetId target_id : remote_event.target_mismatches()) {
    auto found = listen_targets_.find(target_id);
    if (found == listen_targets_.end()) {
      // A watched target might have been removed already.
      continue;
    }
    FSTQueryData* query_data = found->second;

    // Clear the resume token for the query, since we're in a known mismatch
    // state.
    query_data = [[FSTQueryData alloc] initWithQuery:query_data.query
                                           target_id:target_id
                                listenSequenceNumber:query_data.sequenceNumber
                                             purpose:query_data.purpose];
    listen_targets_[target_id] = query_data;

    // Cause a hard reset by unwatching and rewatching immediately, but
    // deliberately don't send a resume token so that we get a full update.
    SendUnwatchRequest(target_id);

    // Mark the query we send as being on behalf of an existence filter
    // mismatch, but don't actually retain that in listen_targets_. This ensures
    // that we flag the first re-listen this way without impacting future
    // listens of this target (that might happen e.g. on reconnect).
    FSTQueryData* request_query_data = [[FSTQueryData alloc]
               initWithQuery:query_data.query
                   target_id:target_id
        listenSequenceNumber:query_data.sequenceNumber
                     purpose:FSTQueryPurposeExistenceFilterMismatch];
    SendWatchRequest(request_query_data);
  }

  // Finally handle remote event
  [sync_engine_ applyRemoteEvent:remoteEvent];
}

void RemoteStore::ProcessTargetError(const WatchTargetChange& change) {
  HARD_ASSERT(!change.cause().ok(), "Handling target error without a cause");

  // Ignore targets that have been removed already.
  for (TargetId target_id : change.target_ids()) {
    auto found = listen_targets_.find(target_id);
    if (found != listen_targets_.end()) {
      listen_targets_.erase(found);
      watch_change_aggregator_->RemoveTarget(target_id);
      [sync_engine_ rejectListenWithTargetID:target_id
                                       error:util::MakeNSError(change.cause())];
    }
  }
}

bool RemoteStore::CanUseNetwork() const {
  // PORTING NOTE: This method exists mostly because web also has to take into
  // account primary vs. secondary state.
  return is_network_enabled_;
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase
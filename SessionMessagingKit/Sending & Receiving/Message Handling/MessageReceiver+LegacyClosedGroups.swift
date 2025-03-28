// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    public static func handleLegacyClosedGroupControlMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard !dependencies[feature: .legacyGroupsDeprecated] else { throw MessageReceiverError.deprecatedMessage }
        
        switch message.kind {
            case .new: try handleNewLegacyClosedGroup(db, message: message, using: dependencies)
            
            case .encryptionKeyPair:
                try handleClosedGroupEncryptionKeyPair(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case .nameChange:
                try handleClosedGroupNameChanged(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case .membersAdded:
                try handleClosedGroupMembersAdded(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case .membersRemoved:
                try handleClosedGroupMembersRemoved(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case .memberLeft:
                try handleClosedGroupMemberLeft(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case .encryptionKeyPairRequest: break // Currently not used
            
            default: throw MessageReceiverError.invalidMessage
        }
    }
    
    // MARK: - Specific Handling
    
    private static func handleNewLegacyClosedGroup(
        _ db: Database,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard case let .new(publicKeyAsData, name, encryptionKeyPair, membersAsData, adminsAsData, expirationTimer) = message.kind else {
            return
        }
        guard
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
            LibSession.canPerformChange(
                db,
                threadId: publicKeyAsData.toHexString(),
                targetConfig: .userGroups,
                changeTimestampMs: Int64(sentTimestampMs),
                using: dependencies
            )
        else {
            // If the closed group already exists then store the encryption keys (since the config only stores
            // the latest key we won't be able to decrypt older messages if we were added to the group within
            // the last two weeks and the key has been rotated - unfortunately if the user was added more than
            // two weeks ago and the keys were rotated within the last two weeks then we won't be able to decrypt
            // messages received before the key rotation)
            let legacyGroupId: String = publicKeyAsData.toHexString()
            let receivedTimestamp: TimeInterval = (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
            let newKeyPair: ClosedGroupKeyPair = ClosedGroupKeyPair(
                threadId: legacyGroupId,
                publicKey: Data(encryptionKeyPair.publicKey),
                secretKey: Data(encryptionKeyPair.secretKey),
                receivedTimestamp: receivedTimestamp
            )
            
            guard
                ClosedGroup.filter(id: legacyGroupId).isNotEmpty(db),
                !ClosedGroupKeyPair
                    .filter(ClosedGroupKeyPair.Columns.threadKeyPairHash == newKeyPair.threadKeyPairHash)
                    .isNotEmpty(db)
            else { return Log.info(.messageReceiver, "Ignoring outdated NEW legacy group message due to more recent config state") }
            
            try newKeyPair.insert(db)
            return
        }
        
        try handleNewLegacyClosedGroup(
            db,
            legacyGroupSessionId: publicKeyAsData.toHexString(),
            name: name,
            encryptionKeyPair: encryptionKeyPair,
            members: membersAsData.map { $0.toHexString() },
            admins: adminsAsData.map { $0.toHexString() },
            expirationTimer: expirationTimer,
            formationTimestampMs: sentTimestampMs,
            forceApprove: false,
            using: dependencies
        )
    }

    internal static func handleNewLegacyClosedGroup(
        _ db: Database,
        legacyGroupSessionId: String,
        name: String,
        encryptionKeyPair: KeyPair,
        members: [String],
        admins: [String],
        expirationTimer: UInt32,
        formationTimestampMs: UInt64,
        forceApprove: Bool,
        using dependencies: Dependencies
    ) throws {
        // With new closed groups we only want to create them if the admin creating the closed group is an
        // approved contact (to prevent spam via closed groups getting around message requests if users are
        // on old or modified clients)
        var hasApprovedAdmin: Bool = false
        let receivedTimestamp: TimeInterval = (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
        
        for adminId in admins {
            if let contact: Contact = try? Contact.fetchOne(db, id: adminId), contact.isApproved {
                hasApprovedAdmin = true
                break
            }
        }
        
        // If we want to force approve the group (eg. if it came from config handling) then it
        // doesn't matter if we have an approved admin - we should add it regardless
        guard hasApprovedAdmin || forceApprove else { return }
        
        // Create the disappearing config
        let disappearingConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
            .defaultWith(legacyGroupSessionId)
            .with(
                isEnabled: (expirationTimer > 0),
                durationSeconds: TimeInterval(expirationTimer),
                type: (expirationTimer > 0 ? .disappearAfterSend : .unknown)
            )
        
        /// Update `libSession` first
        ///
        /// **Note:** This **MUST** happen before we call `SessionThread.upsert` as we won't add the group
        /// if it already exists in `libSession` and upserting the thread results in an update to `libSession` to set
        /// the `priority`
        try? LibSession.add(
            db,
            legacyGroupSessionId: legacyGroupSessionId,
            name: name,
            joinedAt: (TimeInterval(formationTimestampMs) / 1000),
            latestKeyPairPublicKey: Data(encryptionKeyPair.publicKey),
            latestKeyPairSecretKey: Data(encryptionKeyPair.secretKey),
            latestKeyPairReceivedTimestamp: receivedTimestamp,
            disappearingConfig: disappearingConfig,
            members: members.asSet(),
            admins: admins.asSet(),
            using: dependencies
        )
        
        // Create the group
        let thread: SessionThread = try SessionThread.upsert(
            db,
            id: legacyGroupSessionId,
            variant: .legacyGroup,
            values: SessionThread.TargetValues(
                creationDateTimestamp: .setTo((TimeInterval(formationTimestampMs) / 1000)),
                shouldBeVisible: .setTo(true)
            ),
            using: dependencies
        )
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: legacyGroupSessionId,
            name: name,
            formationTimestamp: (TimeInterval(formationTimestampMs) / 1000),
            shouldPoll: true,   // Legacy groups should always poll
            invited: false      // Legacy groups are never in the "invite" state
        ).upserted(db)
        
        // Clear the zombie list if the group wasn't active (ie. had no keys)
        if ((try? closedGroup.keyPairs.fetchCount(db)) ?? 0) == 0 {
            try closedGroup.zombies.deleteAll(db)
        }
        
        // Create the GroupMember records if needed
        try members.forEach { memberId in
            try GroupMember(
                groupId: legacyGroupSessionId,
                profileId: memberId,
                role: .standard,
                roleStatus: .accepted,  // Legacy group members don't have role statuses
                isHidden: false
            ).upsert(db)
        }
        
        try admins.forEach { adminId in
            try GroupMember(
                groupId: legacyGroupSessionId,
                profileId: adminId,
                role: .admin,
                roleStatus: .accepted,  // Legacy group members don't have role statuses
                isHidden: false
            ).upsert(db)
        }
        
        // Update the DisappearingMessages config
        if (try? thread.disappearingMessagesConfiguration.fetchOne(db)) == nil {
            try disappearingConfig.upsert(db)
        }
        
        // Store the key pair if it doesn't already exist
        let newKeyPair: ClosedGroupKeyPair = ClosedGroupKeyPair(
            threadId: legacyGroupSessionId,
            publicKey: Data(encryptionKeyPair.publicKey),
            secretKey: Data(encryptionKeyPair.secretKey),
            receivedTimestamp: receivedTimestamp
        )
        let keyPairExists: Bool = ClosedGroupKeyPair
            .filter(ClosedGroupKeyPair.Columns.threadKeyPairHash == newKeyPair.threadKeyPairHash)
            .isNotEmpty(db)
        
        if !keyPairExists {
            try newKeyPair.insert(db)
        }
        
        // Start polling
        dependencies
            .mutate(cache: .groupPollers) { $0.getOrCreatePoller(for: legacyGroupSessionId) }
            .startIfNeeded()
        
        // Resubscribe for group push notifications
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        (try? PushNotificationAPI
            .preparedSubscribeToLegacyGroups(
                userSessionId: userSessionId,
                legacyGroupIds: try ClosedGroup
                    .select(.threadId)
                    .filter(
                        ClosedGroup.Columns.threadId > SessionId.Prefix.standard.rawValue &&
                        ClosedGroup.Columns.threadId < SessionId.Prefix.standard.endOfRangeString
                    )
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                    )
                    .asRequest(of: String.self)
                    .fetchSet(db)
                    .inserting(legacyGroupSessionId),  // Insert the new key just to be sure
                using: dependencies
            ))?
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
            .sinkUntilComplete()
    }

    /// Extracts and adds the new encryption key pair to our list of key pairs if there is one for our public key, AND the message was
    /// sent by the group admin.
    private static func handleClosedGroupEncryptionKeyPair(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard case let .encryptionKeyPair(explicitGroupPublicKey, wrappers) = message.kind else {
            return
        }
        
        let legacyGroupId: String = (explicitGroupPublicKey?.toHexString() ?? threadId)
        
        guard let userKeyPair: KeyPair = Identity.fetchUserKeyPair(db) else {
            return Log.error(.messageReceiver, "Couldn't find user X25519 key pair.")
        }
        guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: legacyGroupId) else {
            return Log.warn(.messageReceiver, "Ignoring closed group encryption key pair for nonexistent group.")
        }
        guard let groupAdmins: [GroupMember] = try? closedGroup.admins.fetchAll(db) else { return }
        guard let sender: String = message.sender, groupAdmins.contains(where: { $0.profileId == sender }) else {
            return Log.info(.messageReceiver, "Ignoring closed group encryption key pair from non-admin.")
        }
        // Find our wrapper and decrypt it if possible
        let userPublicKey: String = SessionId(.standard, publicKey: userKeyPair.publicKey).hexString
        
        guard
            let wrapper = wrappers.first(where: { $0.publicKey == userPublicKey }),
            let encryptedKeyPair = wrapper.encryptedKeyPair
        else { return }
        
        let plaintext: Data
        do {
            plaintext = try dependencies[singleton: .crypto].tryGenerate(
                .plaintextWithSessionProtocolLegacyGroup(
                    ciphertext: encryptedKeyPair,
                    keyPair: userKeyPair,
                    using: dependencies
                )
            ).plaintext
        }
        catch { return Log.error(.messageReceiver, "Couldn't decrypt closed group encryption key pair.") }
        
        // Parse it
        let proto: SNProtoKeyPair
        do {
            proto = try SNProtoKeyPair.parseData(plaintext)
        }
        catch { return Log.error(.messageReceiver, "Couldn't parse closed group encryption key pair.") }
        
        do {
            let keyPair: ClosedGroupKeyPair = ClosedGroupKeyPair(
                threadId: legacyGroupId,
                publicKey: Data(SessionId(.standard, publicKey: Array(proto.publicKey)).publicKey),
                secretKey: proto.privateKey,
                receivedTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
            )
            try keyPair.insert(db)
            
            // Update libSession
            try? LibSession.update(
                db,
                legacyGroupSessionId: legacyGroupId,
                latestKeyPair: keyPair,
                using: dependencies
            )
        }
        catch {
            if case DatabaseError.SQLITE_CONSTRAINT_UNIQUE = error {
                return Log.info(.messageReceiver, "Ignoring duplicate closed group encryption key pair.")
            }
            
            throw error
        }
        
        Log.info(.messageReceiver, "Received a new closed group encryption key pair.")
    }
    
    private static func handleClosedGroupNameChanged(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let messageKind: ClosedGroupControlMessage.Kind = message.kind,
            case let .nameChange(name) = message.kind
        else { return }
        
        try processIfValid(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            messageKind: messageKind,
            infoMessageVariant: .infoLegacyGroupUpdated,
            using: dependencies,
            legacyGroupChanges: { sender, closedGroup, allMembers in
                // Update libSession
                try? LibSession.update(
                    db,
                    legacyGroupSessionId: threadId,
                    name: name,
                    using: dependencies
                )
                
                _ = try ClosedGroup
                    .filter(id: threadId)
                    .updateAll( // Explicit config update so no need to use 'updateAllAndConfig'
                        db,
                        ClosedGroup.Columns.name.set(to: name)
                    )
            }
        )
    }
    
    private static func handleClosedGroupMembersAdded(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let messageKind: ClosedGroupControlMessage.Kind = message.kind,
            case let .membersAdded(membersAsData) = message.kind
        else { return }
        
        try processIfValid(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            messageKind: messageKind,
            infoMessageVariant: .infoLegacyGroupUpdated,
            using: dependencies,
            legacyGroupChanges: { sender, closedGroup, allMembers in
                // Update the group
                let addedMembers: [String] = membersAsData.map { $0.toHexString() }
                let currentMemberIds: Set<String> = allMembers
                    .filter { $0.role == .standard }
                    .map { $0.profileId }
                    .asSet()
                
                // Update libSession
                try? LibSession.update(
                    db,
                    legacyGroupSessionId: threadId,
                    members: allMembers
                        .filter { $0.role == .standard || $0.role == .zombie }
                        .map { $0.profileId }
                        .asSet()
                        .union(addedMembers),
                    admins: allMembers
                        .filter { $0.role == .admin }
                        .map { $0.profileId }
                        .asSet(),
                    using: dependencies
                )
                
                // Create records for any new members
                try addedMembers
                    .filter { !currentMemberIds.contains($0) }
                    .forEach { memberId in
                        try GroupMember(
                            groupId: threadId,
                            profileId: memberId,
                            role: .standard,
                            roleStatus: .accepted,  // Legacy group members don't have role statuses
                            isHidden: false
                        ).upsert(db)
                    }
                
                // Send the latest encryption key pair to the added members if the current user is
                // the admin of the group
                //
                // This fixes a race condition where:
                // • A member removes another member.
                // • A member adds someone to the group and sends them the latest group key pair.
                // • The admin is offline during all of this.
                // • When the admin comes back online they see the member removed message and generate +
                //   distribute a new key pair, but they don't know about the added member yet.
                // • Now they see the member added message.
                //
                // Without the code below, the added member(s) would never get the key pair that was
                // generated by the admin when they saw the member removed message.
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                if allMembers.contains(where: { $0.role == .admin && $0.profileId == userSessionId.hexString }) {
                    addedMembers.forEach { memberId in
                        MessageSender.sendLatestEncryptionKeyPair(db, to: memberId, for: threadId, using: dependencies)
                    }
                }
                
                // Remove any 'zombie' versions of the added members (in case they were re-added)
                _ = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.zombie)
                    .filter(addedMembers.contains(GroupMember.Columns.profileId))
                    .deleteAll(db)
            }
        )
    }
    
    /// Removes the given members from the group IF
    /// • it wasn't the admin that was removed (that should happen through a `MEMBER_LEFT` message).
    /// • the admin sent the message (only the admin can truly remove members).
    /// If we're among the users that were removed, delete all encryption key pairs and the group public key, unsubscribe
    /// from push notifications for this closed group, and remove the given members from the zombie list for this group.
    private static func handleClosedGroupMembersRemoved(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let messageKind: ClosedGroupControlMessage.Kind = message.kind,
            case let .membersRemoved(membersAsData) = messageKind
        else { return }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let removedMemberIds: [String] = membersAsData.map { $0.toHexString() }
        
        try processIfValid(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            messageKind: messageKind,
            infoMessageVariant: (removedMemberIds.contains(userSessionId.hexString) ?
                .infoLegacyGroupCurrentUserLeft :
                .infoLegacyGroupUpdated
            ),
            using: dependencies,
            legacyGroupChanges: { sender, closedGroup, allMembers in
                let removedMembers = membersAsData.map { $0.toHexString() }
                let currentMemberIds: Set<String> = allMembers
                    .filter { $0.role == .standard }
                    .map { $0.profileId }
                    .asSet()
                let members = currentMemberIds.subtracting(removedMembers)
                
                // Check that the group creator is still a member and that the message was
                // sent by a group admin
                guard
                    let firstAdminId: String = allMembers.filter({ $0.role == .admin })
                        .first?
                        .profileId,
                    members.contains(firstAdminId),
                    allMembers
                        .filter({ $0.role == .admin })
                        .contains(where: { $0.profileId == sender })
                else { return Log.warn(.messageReceiver, "Ignoring invalid closed group update.") }
                
                // Update libSession
                try? LibSession.update(
                    db,
                    legacyGroupSessionId: threadId,
                    members: allMembers
                        .filter { $0.role == .standard || $0.role == .zombie }
                        .map { $0.profileId }
                        .asSet()
                        .subtracting(removedMembers),
                    admins: allMembers
                        .filter { $0.role == .admin }
                        .map { $0.profileId }
                        .asSet(),
                    using: dependencies
                )
                
                // Delete the removed members
                try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(removedMembers.contains(GroupMember.Columns.profileId))
                    .filter([ GroupMember.Role.standard, GroupMember.Role.zombie ].contains(GroupMember.Columns.role))
                    .deleteAll(db)
                
                // If the current user was removed:
                // • Stop polling for the group
                // • Remove the key pairs associated with the group
                // • Notify the PN server
                let wasCurrentUserRemoved: Bool = !members.contains(userSessionId.hexString)
                
                if wasCurrentUserRemoved {
                    try ClosedGroup.removeData(
                        db,
                        threadIds: [threadId],
                        dataToRemove: .allData,
                        using: dependencies
                    )
                }
            }
        )
    }
    
    /// If a regular member left:
    /// • Mark them as a zombie (to be removed by the admin later).
    /// If the admin left:
    /// • Unsubscribe from PNs, delete the group public key, etc. as the group will be disbanded.
    private static func handleClosedGroupMemberLeft(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let messageKind: ClosedGroupControlMessage.Kind = message.kind,
            case .memberLeft = messageKind
        else { return }
        
        try processIfValid(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            messageKind: messageKind,
            infoMessageVariant: .infoLegacyGroupUpdated,
            using: dependencies,
            legacyGroupChanges: { sender, closedGroup, allMembers in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let didAdminLeave: Bool = allMembers.contains(where: { member in
                    member.role == .admin && member.profileId == sender
                })
                let members: [GroupMember] = allMembers.filter { $0.role == .standard }
                let memberIdsToRemove: [String] = members
                    .filter { member in
                        didAdminLeave || // If the admin leaves the group is disbanded
                        member.profileId == sender
                    }
                    .map { $0.profileId }
                
                // Update libSession
                try? LibSession.update(
                    db,
                    legacyGroupSessionId: threadId,
                    members: allMembers
                        .filter { $0.role == .standard || $0.role == .zombie }
                        .map { $0.profileId }
                        .asSet()
                        .subtracting(memberIdsToRemove),
                    admins: allMembers
                        .filter { $0.role == .admin }
                        .map { $0.profileId }
                        .asSet(),
                    using: dependencies
                )
                
                // Delete the members to remove
                try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(memberIdsToRemove.contains(GroupMember.Columns.profileId))
                    .deleteAll(db)
                
                if didAdminLeave || sender == userSessionId.hexString {
                    try ClosedGroup.removeData(
                        db,
                        threadIds: [threadId],
                        dataToRemove: (sender == userSessionId.hexString ? .allData : .noData),
                        using: dependencies
                    )
                }
                
                // Re-add the removed member as a zombie (unless the admin left which disbands the
                // group)
                if !didAdminLeave {
                    try GroupMember(
                        groupId: threadId,
                        profileId: sender,
                        role: .zombie,
                        roleStatus: .accepted,  // Legacy group members don't have role statuses
                        isHidden: false
                    ).upsert(db)
                }
            }
        )
    }
    
    // MARK: - Convenience
    
    private static func processIfValid(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ClosedGroupControlMessage,
        messageKind: ClosedGroupControlMessage.Kind,
        infoMessageVariant: Interaction.Variant,
        using dependencies: Dependencies,
        legacyGroupChanges: (String, ClosedGroup, [GroupMember]) throws -> ()
    ) throws {
        guard let sender: String = message.sender else { return }
        guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: threadId) else {
            return Log.warn(.messageReceiver, "Ignoring group update for nonexistent group.")
        }
        
        let timestampMs: Int64 = (
            message.sentTimestampMs.map { Int64($0) } ??
            dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        )
        
        // Only actually make the change if LibSession says we can (we always want to insert the info
        // message though)
        if LibSession.canPerformChange(db, threadId: threadId, targetConfig: .userGroups, changeTimestampMs: timestampMs, using: dependencies) {
            // Legacy groups used these control messages for making changes, new groups only use them
            // for information purposes
            switch threadVariant {
                case .legacyGroup:
                    // Check that the message isn't from before the group was created
                    guard Double(message.sentTimestampMs ?? 0) > closedGroup.formationTimestamp else {
                        return Log.warn(.messageReceiver, "Ignoring legacy group update from before thread was created.")
                    }
                    
                    // If these values are missing then we probably won't be able to validly handle the message
                    guard
                        let allMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db),
                        allMembers.contains(where: { $0.profileId == sender })
                    else { return Log.warn(.messageReceiver, "Ignoring legacy group update from non-member.") }
                    
                    try legacyGroupChanges(sender, closedGroup, allMembers)
                    
                case .group:
                    // TODO: [GROUPS REBUILD] Need to check if the user has access to historic messages
                    break
                    
                default: return // Ignore as invalid
            }
        }
        
        // Ensure the group still exists before inserting the info message
        guard ClosedGroup.filter(id: threadId).isNotEmpty(db) else { return }
        
        // Insert the info message for this group control message
        // Note: Control messages for legacy groups are not affected by disappearing messages setting
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: sender,
            variant: infoMessageVariant,
            body: messageKind
                .infoMessage(db, sender: sender, using: dependencies),
            timestampMs: (
                message.sentTimestampMs.map { Int64($0) } ??
                dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            ),
            using: dependencies
        ).inserted(db)
    }
}

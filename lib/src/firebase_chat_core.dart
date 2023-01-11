import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {
  FirebaseChatCore(this.userId) {
    firestore = FirebaseFirestore.instance;
    roomsCollection = firestore.collection(roomsCollectionName);

    database = FirebaseDatabase.instance;
    usersRef = database.ref('users');
  }

  final String userId;
  final String roomsCollectionName = 'rooms';
  late FirebaseFirestore firestore;
  late CollectionReference roomsCollection;

  late FirebaseDatabase database;
  late DatabaseReference usersRef;

  final List<String> superAdmins = [
    'joonas@rebound.business',
    'mikelis@prog.lv',
    'marcis.andersons@prog.lv',
  ];

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    final currentUser = await fetchUserDatabase(usersRef: usersRef, userId: userId);

    final roomUsers = [types.User.fromJson(currentUser)] + users;

    await roomsCollection.doc(name).set({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, user) => {
          ...previousValue,
          user.id: user.role?.toShortString(),
        },
      ),
    });

    return types.Room(
      id: name,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    types.User otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    // Sort two user ids array to always have the same array for both users,
    // this will make it easy to find the room if exist and make one read only.
    final userIds = [userId, otherUser.id]..sort();

    final roomQuery = await roomsCollection
        .where('type', isEqualTo: types.RoomType.direct.toShortString())
        .where('userIds', isEqualTo: userIds)
        .limit(1)
        .get();

    // Check if room already exist.
    if (roomQuery.docs.isNotEmpty) {
      final room = (await processRoomsQuery(
        userId,
        roomQuery as QuerySnapshot<Map<String, dynamic>>,
        usersRef,
      ))
          .first;

      return room;
    }

    // To support old chats created without sorted array,
    // try to check the room by reversing user ids array.
    final oldRoomQuery = await roomsCollection
        .where('type', isEqualTo: types.RoomType.direct.toShortString())
        .where('userIds', isEqualTo: userIds.reversed.toList())
        .limit(1)
        .get();

    // Check if room already exist.
    if (oldRoomQuery.docs.isNotEmpty) {
      final room = (await processRoomsQuery(
        userId,
        oldRoomQuery as QuerySnapshot<Map<String, dynamic>>,
        usersRef,
      ))
          .first;

      return room;
    }

    final currentUser = await fetchUserDatabase(
      usersRef: usersRef,
      userId: userId,
    );

    final users = [types.User.fromJson(currentUser), otherUser];

    // Create new room with sorted user ids array.
    final room = await roomsCollection.add({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': types.RoomType.direct.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': userIds,
      'userRoles': null,
    });

    return types.Room(
      id: room.id,
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  Future<types.Room?> fetchRoom(String roomName) async {
    final doc = await roomsCollection.doc(roomName).get();
    types.Room? room;
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>;
      data['createdAt'] = (data['createdAt'] as Timestamp).millisecondsSinceEpoch;
      data['updatedAt'] = (data['updatedAt'] as Timestamp).millisecondsSinceEpoch;

      room = types.Room.fromJson(data);
    }
    return room;
  }

  Future<types.Room> addUserToGroupGroup(String userId, String roomName) async {
    var room = await fetchRoom(roomName);
    if (room == null) {
      return Future.error("No room with name '$roomName'");
    }
    final users = room.users;
    final user = await constructUser(userId);
    users.add(user);
    room = room.copyWith(users: users);

    await roomsCollection.doc(room.name).set(room.toJson());

    return room;
  }

  Future<types.User> constructUser(String userId) async {
    var user = types.User(id: userId);
    Map<String, dynamic>? metadata = {};
    final userRef = usersRef.child(userId);
    var snapshot = await userRef.child('email').get();

    if (snapshot.value != null) {
      metadata['email'] = snapshot.value;
    }

    snapshot = await userRef.child('registered').get();
    if (snapshot.value != null) {
      final mill = formatToTimestamp(snapshot.value as String).millisecondsSinceEpoch;
      user = user.copyWith(createdAt: mill);
    }

    snapshot = await userRef.child('name').get();
    if (snapshot.value != null) {
      user = user.copyWith(firstName: snapshot.value as String);
    }

    snapshot = await userRef.child('machineNumber').get();
    if (snapshot.value != null) {
      metadata['machineNumber'] = snapshot.value;
    }

    snapshot = await userRef.child('phone').get();
    if (snapshot.value != null) {
      metadata['phone'] = snapshot.value;
    }

    user = user.copyWith(
      metadata: metadata,
      role: (metadata['email'] != null && superAdmins.contains(metadata['email'])) ? types.Role.admin : types.Role.user,
    );

    return user;
  }

  /// Removes message document.
  Future<void> deleteMessage(String roomId, String messageId) async {
    await firestore.collection('$roomsCollectionName/$roomId/messages').doc(messageId).delete();
  }

  /// Removes room document.
  Future<void> deleteRoom(String roomId) async {
    await roomsCollection.doc(roomId).delete();
  }

  /// Returns a stream of messages from Firebase for a given room.
  Stream<List<types.Message>> messages(
    types.Room room, {
    List<Object?>? endAt,
    List<Object?>? endBefore,
    int? limit,
    List<Object?>? startAfter,
    List<Object?>? startAt,
  }) {
    var query = firestore.collection('$roomsCollectionName/${room.id}/messages').orderBy('createdAt', descending: true);

    if (endAt != null) {
      query = query.endAt(endAt);
    }

    if (endBefore != null) {
      query = query.endBefore(endBefore);
    }

    if (limit != null) {
      query = query.limit(limit);
    }

    if (startAfter != null) {
      query = query.startAfter(startAfter);
    }

    if (startAt != null) {
      query = query.startAt(startAt);
    }

    return query.snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.Message>>(
            [],
            (previousValue, doc) {
              final data = doc.data();
              final author = room.users.firstWhere(
                (u) => u.id == data['authorId'],
                orElse: () => types.User(id: data['authorId'] as String),
              );

              data['author'] = author.toJson();
              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
              data['id'] = doc.id;
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

              return [...previousValue, types.Message.fromJson(data)];
            },
          ),
        );
  }

  /// Returns a stream of changes in a room from Firebase.
  Stream<types.Room> room(String roomId) => roomsCollection.doc(roomId).snapshots().asyncMap(
        (doc) => processRoomDocument(
          doc as DocumentSnapshot<Map<String, dynamic>>,
          userId,
          usersRef,
        ),
      );

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`
  Stream<List<types.Room>> rooms({bool orderByUpdatedAt = false}) {
    final collection = orderByUpdatedAt
        ? roomsCollection.where('userIds', arrayContains: userId).orderBy('updatedAt', descending: true)
        : roomsCollection.where('userIds', arrayContains: userId);

    return collection.snapshots().asyncMap(
          (query) => processRoomsQuery(
            userId,
            query as QuerySnapshot<Map<String, dynamic>>,
            usersRef,
          ),
        );
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(dynamic partialMessage, String roomId) async {
    types.Message? message;

    if (partialMessage is types.PartialCustom) {
      message = types.CustomMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialCustom: partialMessage,
      );
    } else if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = userId;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();

      await firestore.collection('$roomsCollectionName/$roomId/messages').add(messageMap);

      await roomsCollection.doc(roomId).update({'updatedAt': FieldValue.serverTimestamp()});
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(types.Message message, String roomId) async {
    if (message.author.id != userId) return;

    final messageMap = message.toJson();
    messageMap.removeWhere(
      (key, value) => key == 'author' || key == 'createdAt' || key == 'id',
    );
    messageMap['authorId'] = message.author.id;
    messageMap['updatedAt'] = FieldValue.serverTimestamp();

    await firestore.collection('$roomsCollectionName/$roomId/messages').doc(message.id).update(messageMap);
  }

  /// Updates a room in the Firestore. Accepts any room.
  /// Room will probably be taken from the [rooms] stream.
  void updateRoom(types.Room room) async {
    final roomMap = room.toJson();
    roomMap.removeWhere((key, value) => key == 'createdAt' || key == 'id' || key == 'lastMessages' || key == 'users');

    if (room.type == types.RoomType.direct) {
      roomMap['imageUrl'] = null;
      roomMap['name'] = null;
    }

    roomMap['lastMessages'] = room.lastMessages?.map((m) {
      final messageMap = m.toJson();

      messageMap
          .removeWhere((key, value) => key == 'author' || key == 'createdAt' || key == 'id' || key == 'updatedAt');

      messageMap['authorId'] = m.author.id;

      return messageMap;
    }).toList();
    roomMap['updatedAt'] = FieldValue.serverTimestamp();
    roomMap['userIds'] = room.users.map((u) => u.id).toList();

    await roomsCollection.doc(room.id).update(roomMap);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:get/get.dart';
import 'package:isar/isar.dart';
import 'package:wenznote/commons/util/serial_util.dart';
import 'package:wenznote/model/note/po/doc_state_po.dart';
import 'package:wenznote/service/service_manager.dart';
import 'package:wenznote/service/sync/p2p_packet.pb.dart';
import 'package:web_socket_channel/io.dart';

class MessageType {
  static const int heart = -1;
  static const int updateRecordEvent = 1;

  /// 文档更新消息
  static const int docEditEvent = 2;
  static const int queryDocDelta = 3;
  static const int docDelta = 4;

  /// 下载 doc 指令，通知客户端去下载完整的 doc 文件
  static const int downloadDoc = 5;
  static const int queryDocState = 6;
  static const int docState = 7;
}

class UpdateInfo {
  String? dataId;
}

class P2pService {
  ServiceManager serviceManager;
  IOWebSocketChannel? socket;
  bool isUserClosed = false;
  Timer? heartTimer;

  P2pService(this.serviceManager);

  void connect() {
    _reconnect();
  }

  void close() {
    isUserClosed = true;
    _reconnect();
  }

  void _reconnect() {
    heartTimer?.cancel();
    heartTimer = null;
    socket?.sink.close();
    socket = null;
    if (isUserClosed) {
      return;
    }
    var noteServer = serviceManager.userService.noteServer;
    if (noteServer == null) {
      return;
    }
    var token = serviceManager.userService.token;
    if(token==null){
      return;
    }
    var clientId = serviceManager.userService.clientId;
    var uri = Uri.parse(
        "ws://${noteServer.host}:${noteServer.port}/client/websocket/$clientId");
    socket = IOWebSocketChannel.connect(uri,
        headers: {'token': token});
    socket!.stream.listen(
      (data) {
        _onReceive(data);
      },
      onDone: () {
        Timer(const Duration(seconds: 5), () {
          _reconnect();
        });
      },
      onError: (err) {
        print(err);
      },
    );
    heartTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      sendHeartMessage();
    });
  }

  void _onReceive(data) {
    if (data is! Uint8List) {
      return;
    }
    int clientCount = readInt32(data, 0);
    if (clientCount < 0) {
      // 心跳消息
      return;
    }
    dealMessage(data, 4 + 8 * clientCount);
  }

  void dealMessage(Uint8List data, int offset) {
    var decode = serviceManager.cryptService.decode(data.sublist(offset));
    var pkt = P2pPacket.fromBuffer(decode);
    switch (pkt.type) {
      case MessageType.updateRecordEvent:
        // 记录更新消息
        serviceManager.recordSyncService.pullDbData(dataIdList: pkt.dataIdList);
        break;
      case MessageType.docEditEvent:
        // 编辑文档消息
        serviceManager.docSnapshotService.receiveDocEditEvent(pkt);
        break;
      case MessageType.queryDocDelta:
        // 查询文档增量消息
        serviceManager.docSnapshotService.queryDocDelta(pkt);
        break;
      case MessageType.docDelta:
        // 文档增量更新消息
        serviceManager.docSnapshotService.receiveDocDelta(pkt);
        break;
      case MessageType.downloadDoc:
        // 下载文档消息
        serviceManager.docSnapshotService.downloadDoc(pkt);
        break;
      case MessageType.queryDocState:
        // 查询 docState 消息
        serviceManager.docSnapshotService.queryDocState(pkt);
        break;
      case MessageType.docState:
        // 收到 docState 消息
        serviceManager.docSnapshotService.receiveDocState(pkt);
        break;
    }
  }

  void sendHeartMessage() {
    var bytes = writeInt32(-1);
    var buff = Uint8List.fromList(bytes);
    socket?.sink.add(buff);
  }

  void sendPkt({
    required int messageType,
    List<int>? toClientIds,
    List<String>? dataIdList,
    List<int>? content,
    int? clientTime,
  }) {
    if (socket == null) {
      return;
    }
    var pkt = P2pPacket.create();
    pkt.clientId = Int64(serviceManager.userService.clientId);
    pkt.type = messageType;
    if (content != null) {
      pkt.content = content;
    }
    if (dataIdList != null) {
      pkt.dataIdList.addAll(dataIdList);
    }
    if (clientTime != null) {
      pkt.clientTime = Int64(clientTime);
    }
    List<int> data;
    if (toClientIds != null && toClientIds.isNotEmpty) {
      data = writeInt32(toClientIds.length);
      for (var clientId in toClientIds) {
        data.addAll(writeLong(clientId));
      }
    } else {
      data = writeInt32(0);
    }
    var pktContent = serviceManager.cryptService.encode(pkt.writeToBuffer());
    data.addAll(pktContent);
    socket?.sink.add(Uint8List.fromList(data));
  }

  void sendUpdateRecordMessage(List<String> idList) {
    sendPkt(
      messageType: MessageType.updateRecordEvent,
      dataIdList: idList,
    );
  }

  void sendDocEditMessage(String dataId, Uint8List delta) {
    sendPkt(
      messageType: MessageType.docEditEvent,
      content: delta,
      dataIdList: [dataId],
    );
  }

  void sendQueryDocMessage(String dataId, Uint8List snap) {
    sendPkt(
      messageType: MessageType.queryDocDelta,
      content: snap,
      dataIdList: [dataId],
    );
  }

  void sendDocDeltaMessage(
      int toClientId, String dataId, int clientTime, Uint8List docContent) {
    sendPkt(
      toClientIds: [toClientId],
      messageType: MessageType.docDelta,
      content: docContent,
      clientTime: clientTime,
      dataIdList: [dataId],
    );
  }

  /// 发送查询差异文档消息
  Future<void> sendQueryDocStateMessage() async {
    // 得到本地 client state
    var isar = serviceManager.isarService.documentIsar;
    var states = await isar.docStatePOs.where().findAll();
    var stateMap = <int, int>{};
    for (var value in states) {
      var clientId = value.clientId;
      var time = value.updateTime;
      if (clientId == null || time == null) {
        continue;
      }
      var oldItem = stateMap[clientId];
      if (oldItem == null) {
        stateMap[clientId] = time;
      } else {
        stateMap[clientId] = max(time, oldItem);
      }
    }
    // 发送
    var content = utf8.encode(jsonEncode(stateMap));
    sendPkt(messageType: MessageType.queryDocState, content: content);
  }

  void sendDownloadDocMessage(int clientId, String dataId) {
    sendPkt(
        messageType: MessageType.downloadDoc,
        dataIdList: [dataId],
        toClientIds: [clientId]);
  }

  void sendDocStateMessage(int clientId, String states) {
    sendPkt(
        messageType: MessageType.docState,
        toClientIds: [clientId],
        content: utf8.encode(states));
  }
}

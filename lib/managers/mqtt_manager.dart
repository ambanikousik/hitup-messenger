import 'dart:convert';

import 'package:coocoo/blocs/chats/chat_bloc.dart';
import 'package:coocoo/blocs/home/home_bloc.dart';
import 'package:coocoo/config/Constants.dart';
import 'package:coocoo/stateProviders/mqtt_state.dart';
import 'package:coocoo/utils/SharedObjects.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:provider/provider.dart';

import 'db_manager.dart';

class MQTTManager {
  MQTTManager({
    @required this.serverAddress,
    @required this.clientName,
    @required this.context,
  });

  final String serverAddress;
  final String clientName;
  final BuildContext context;
  MqttServerClient _client;

  ChatBloc chatBloc;
  HomeBloc homeBloc;

  void initializeMQTTClient() {
    _client = MqttServerClient(serverAddress, clientName);
    _client.port = 1883;
    _client.keepAlivePeriod = 43200;
    _client.logging(on: false);
    _client.onDisconnected = onDisconnected;
    _client.onConnected = onConnect;

    // auto reconnecting when client is disconnected to server
    _client.autoReconnect = true;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientName)
        .keepAliveFor(
            43200) // Must agree with the keep alive set above or not set
        .withWillTopic(
            'willtopic') // If you set this you must set a will message
        .withWillMessage('My Will message')
        .withWillRetain()
        .withWillQos(MqttQos.atLeastOnce);

    _client.connectionMessage = connMess;
  }

  void disconnect() {
    _client.disconnect();
  }

  bool getConnectionStatus() {
    if (_client.connectionStatus.state == MqttConnectionState.connected) {
      return true;
    } else {
      return false;
    }
  }

  Future<void> connect(String username, String password) async {
    try {
      await _client.connect(username, password);
    } on Exception catch (e) {
      print('EXAMPLE::client exception - $e');
      _client.disconnect();
    }
  }

  void subscribeTopic(String topic) {
    _client.subscribe(topic, MqttQos.atLeastOnce);

    /// The client has a change notifier object(see the Observable class) which we then listen to to get
    /// notifications of published updates to each subscribed topic.
  }

  void unSubscribeTopic(String topic) {
    _client.unsubscribe(topic);
  }

  Stream<List<MqttReceivedMessage<MqttMessage>>> get messageStream =>
      _client.updates;

  void publish(String myMessage, String topic) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(myMessage);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload,
        retain: true);
  }

  void onDisconnected() {
    print('Client Disconnect');
  }

  void onConnect() {
    chatBloc = BlocProvider.of<ChatBloc>(context);
    homeBloc = BlocProvider.of<HomeBloc>(context);
    _client.updates.listen((List<MqttReceivedMessage<MqttMessage>> c) async {
      final MqttPublishMessage recMess = c[0].payload;
      final String chatId = c[0].topic;
      final msg =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

      print("THIS IS THE MESSAGE BEFORE DECODING");
      print(msg);
      Map parsedMsg = json.decode(msg);
      final int currTime = DateTime.now().millisecondsSinceEpoch;

      print(
          "CHATTTTTIDDDD : $chatId,  MSGGGGGGGG : $parsedMsg, CUUUUURRRRRRRTIIIIIIME : $currTime");
      if (parsedMsg["type"] == "service") {
        if (parsedMsg["msg"] == Constants.profilePicChangeMsg) {
          String myUid = SharedObjects.prefs.getString(Constants.sessionUid);
          if (parsedMsg["uid"] != myUid) {
            print("Profile Pic Changed For $chatId");
            await DBManager.db.updateProfilePicInContactsTable(
                parsedMsg["profilePicUrl"], chatId);
            homeBloc.add(FetchHomeChatsEvent());
          }
        }
      } else {
        // save the message to local db to that chatId
        await DBManager.db.updateMessageToDb(
            chatId, parsedMsg["msg"], parsedMsg["type"], currTime);

        //also notify the bloc that a new message is received so that it
        // may read the last message from the local db
        chatBloc.add(ReceivedMessageEvent(chatId));

        // set the last msg sender & last Msg
        context.read<MQTTState>().setLastSender(chatId, parsedMsg["uid"]);
        context.read<MQTTState>().setLastMsg(chatId, parsedMsg["msg"]);

        // fetching the chatcards for the homePage
        homeBloc.add(FetchHomeChatsEvent());
      }
    });
  }
}
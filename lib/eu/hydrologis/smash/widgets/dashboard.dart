/*
 * Copyright (c) 2019. Antonello Andrea (www.hydrologis.com). All rights reserved.
 * Use of this source code is governed by a GPL3 license that can be
 * found in the LICENSE file.
 */
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/database/database_widgets.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/database/project_tables.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/gps/gps.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/maps/geocoding.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/maps/mapsforge.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/models/models.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/colors.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/dialogs.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/files.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/logging.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/preferences.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/share.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/utils.dart';
import 'package:geopaparazzi_light/eu/geopaparazzi/library/utils/validators.dart';
import 'package:geopaparazzi_light/eu/hydrologis/smash/widgets/notes_ui.dart';
import 'package:latlong/latlong.dart';
import 'package:path/path.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen/screen.dart';
import 'package:badges/badges.dart';

class DashboardWidget extends StatefulWidget {
  DashboardWidget({Key key}) : super(key: key);

  @override
  _DashboardWidgetState createState() => new _DashboardWidgetState();
}

class _DashboardWidgetState extends State<DashboardWidget>
    implements PositionListener {
  GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  ValueNotifier<bool> _keepGpsOnScreenNotifier = new ValueNotifier(false);
  ValueNotifier<LatLng> _mapCenterValueNotifier =
      new ValueNotifier(LatLng(0, 0));

  List<Marker> _geopapMarkers;
  PolylineLayerOptions _geopapLogs;
  Polyline _currentGeopapLog =
      Polyline(points: [], strokeWidth: 3, color: ColorExt("red"));
  TileLayerOptions _osmLayer;
  Position _lastPosition;

  double _initLon;
  double _initLat;
  double _initZoom;

  MapController _mapController;

  TileLayerOptions _mapsforgeLayer;

  Size _media;

  String _projectName = "No project loaded";
  String _projectDirName = null;
  int _notesCount = 0;
  int _logsCount = 0;

  ValueNotifier<GpsStatus> _gpsStatusValueNotifier =
      new ValueNotifier(GpsStatus.OFF);
  ValueNotifier<bool> _gpsLoggingValueNotifier = new ValueNotifier(false);

  @override
  void initState() {
    Screen.keepOn(true);

    _initLon = gpProjectModel.lastCenterLon;
    _initLat = gpProjectModel.lastCenterLat;
    _initZoom = gpProjectModel.lastCenterZoom;

    _mapController = MapController();
    _osmLayer = new TileLayerOptions(
      urlTemplate: "https://{s}.tile.openstreetmap.org/"
          "{z}/{x}/{y}.png",
      backgroundColor: SmashColors.mainBackground,
      maxZoom: 19,
      subdomains: ['a', 'b', 'c'],
    );

    _mapCenterValueNotifier.addListener(() {
      _mapController.move(_mapCenterValueNotifier.value, _mapController.zoom);
    });

    _checkPermissions().then((allRight) async {
      if (allRight) {
        bool init = await GpLogger().init(); // init logger
        if (init) GpLogger().d("Db logger initialized.");

        // start gps listening
        GpsHandler().addPositionListener(this);

        // check center on gps
        bool centerOnGps = await GpPreferences().getCenterOnGps();
        _keepGpsOnScreenNotifier.value = centerOnGps;

        // set initial status
        bool gpsIsOn = await GpsHandler().isGpsOn();
        if (gpsIsOn != null) {
          if (gpsIsOn) {
            _gpsStatusValueNotifier.value = GpsStatus.ON_NO_FIX;
          }
        }

        // load mapsforge maps
        var mapsforgePath =
            await GpPreferences().getString(KEY_LAST_MAPSFORGEPATH);
        if (mapsforgePath != null) {
          File mapsforgeFile = new File(mapsforgePath);
          if (mapsforgeFile.existsSync()) {
            _mapsforgeLayer = await loadMapsforgeLayer(mapsforgeFile);
          }
        }

        await loadCurrentProject();
        setState(() {});
      }
    });

    super.initState();
  }

  _showSnackbar(snackbar) {
    _scaffoldKey.currentState.showSnackBar(snackbar);
  }

  _hideSnackbar() {
    _scaffoldKey.currentState.hideCurrentSnackBar();
  }

  Future<bool> _checkPermissions() async {
    List<PermissionGroup> mandatory = [];
    PermissionStatus permission = await PermissionHandler()
        .checkPermissionStatus(PermissionGroup.storage);
    if (permission != PermissionStatus.granted) {
      GpLogger().d("Storage permission is not granted.");
      mandatory.add(PermissionGroup.storage);
    }
    permission = await PermissionHandler()
        .checkPermissionStatus(PermissionGroup.location);
    if (permission != PermissionStatus.granted) {
      GpLogger().d("Location permission is not granted.");
      mandatory.add(PermissionGroup.location);
    }

    if (mandatory.length > 0) {
      Map<PermissionGroup, PermissionStatus> permissionsMap =
          await PermissionHandler().requestPermissions(mandatory);
      if (permissionsMap[PermissionGroup.storage] != PermissionStatus.granted) {
        GpLogger().d("Unable to grant storage permission");
        return false;
      }
      if (permissionsMap[PermissionGroup.location] !=
          PermissionStatus.granted) {
        GpLogger().d("Unable to grant location permission");
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _media = MediaQuery.of(context).size;

    var layers = <LayerOptions>[];
    if (_mapsforgeLayer != null) {
      layers.add(_mapsforgeLayer);
    }

    if (_geopapLogs != null) layers.add(_geopapLogs);
    if (_geopapMarkers != null && _geopapMarkers.length > 0) {
      var markerCluster = MarkerClusterLayerOptions(
        maxClusterRadius: 80,
        height: 40,
        width: 40,
        fitBoundsOptions: FitBoundsOptions(
          padding: EdgeInsets.all(50),
        ),
        markers: _geopapMarkers,
        polygonOptions: PolygonOptions(
            borderColor: SmashColors.mainDecorationsDark,
            color: SmashColors.mainDecorations.withOpacity(0.2),
            borderStrokeWidth: 3),
        builder: (context, markers) {
          return FloatingActionButton(
            child: Text(markers.length.toString()),
            onPressed: null,
            backgroundColor: SmashColors.mainDecorationsDark,
            foregroundColor: SmashColors.mainBackground,
            heroTag: null,
          );
        },
      );
      layers.add(markerCluster);
    }

    if (GpsHandler().currentLogPoints.length > 0) {
      _currentGeopapLog.points.clear();
      _currentGeopapLog.points.addAll(GpsHandler().currentLogPoints);
      layers.add(PolylineLayerOptions(
        polylines: [_currentGeopapLog],
      ));
    }

    if (_lastPosition != null) {
      layers.add(
        MarkerLayerOptions(
          markers: [
            Marker(
              width: 80.0,
              height: 80.0,
              anchorPos: AnchorPos.align(AnchorAlign.center),
              point:
                  new LatLng(_lastPosition.latitude, _lastPosition.longitude),
              builder: (ctx) => new Container(
                    child: Icon(
                      Icons.my_location,
                      size: 32,
                      color: Colors.black,
                    ),
                  ),
            )
          ],
        ),
      );
    }

    var bar = new AppBar(
      title: Padding(
        padding: const EdgeInsets.only(top: 10.0, bottom: 10.0),
        child: Image.asset("assets/smash_text.png", fit: BoxFit.cover),
      ),
      actions: <Widget>[
        IconButton(
            icon: Icon(Icons.info_outline),
            onPressed: () {
              String gpsInfo = "";
              if (_lastPosition != null) {
                gpsInfo = '''
Last position:
  Latitude: ${_lastPosition.latitude}
  Longitude: ${_lastPosition.longitude}
  Altitude: ${_lastPosition.altitude.round()} m
  Accuracy: ${_lastPosition.accuracy.round()} m
  Heading: ${_lastPosition.heading}
  Speed: ${_lastPosition.speed} m/s
  Timestamp: ${GpConstants.ISO8601_TS_FORMATTER.format(_lastPosition.timestamp)}''';
              }
              showInfoDialog(
                  context,
                  '''Project: $_projectName
${_projectDirName != null ? "Folder: $_projectDirName\n" : ""}
$gpsInfo
'''
                      .trim(),
                  dialogHeight: _media.height / 2);
            })
      ],
    );
    return WillPopScope(
        // check when the app is left
        child: new Scaffold(
          key: _scaffoldKey,
          appBar: bar,
          backgroundColor: SmashColors.mainBackground,
          body: FlutterMap(
            options: new MapOptions(
              center: new LatLng(_initLat, _initLon),
              zoom: _initZoom,
              plugins: [
                MarkerClusterPlugin(),
              ],
            ),
            layers: layers,
            mapController: _mapController,
          ),
          drawer: Drawer(
              child: ListView(
            children: _getDrawerWidgets(context),
          )),
          endDrawer: Drawer(
              child: ListView(
            children: getEndDrawerWidgets(context),
          )),
          bottomNavigationBar: BottomAppBar(
            color: SmashColors.mainDecorations,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: <Widget>[
                makeToolbarBadge(
                    IconButton(
                      onPressed: () async {
                        bool doInGps = await GpPreferences()
                            .getBoolean(KEY_NOTEDOGPS, true);
                        int ts = DateTime.now().millisecondsSinceEpoch;
                        Position pos;
                        double lon;
                        double lat;
                        if (doInGps) {
                          pos = GpsHandler().lastPosition;
                        } else {
                          lon = gpProjectModel.lastCenterLon;
                          lat = gpProjectModel.lastCenterLat;
                        }
                        Note note = Note()
                          ..text = "double tap to change"
                          ..description = "double tap to change"
                          ..timeStamp = ts
                          ..lon = pos != null ? pos.longitude : lon
                          ..lat = pos != null ? pos.latitude : lat
                          ..altim = pos != null ? pos.altitude : -1;
                        if (pos != null) {
                          NoteExt next = NoteExt()
                            ..speedaccuracy = pos.speedAccuracy
                            ..speed = pos.speed
                            ..heading = pos.heading
                            ..accuracy = pos.accuracy;
                          note.noteExt = next;
                        }
                        var db = await gpProjectModel.getDatabase();
                        await db.addNote(note);

                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    NotePropertiesWidget(reloadProject, note)));
                      },
                      tooltip: 'Notes',
                      icon: Icon(
                        Icons.note,
                        color: SmashColors.mainBackground,
                      ),
                    ),
                    _notesCount),
                makeToolbarBadge(
                    LoggingButton(
                        _gpsStatusValueNotifier, reloadProject, moveTo),

//                    IconButton(
//                      onPressed: () {
//                        Navigator.push(
//                            context,
//                            MaterialPageRoute(
//                                builder: (context) =>
//                                    LogListWidget(reloadProject, moveTo)));
//                      },
//                      tooltip: 'Logs',
//                      icon: Icon(
//                        Icons.timeline,
//                        color: SmashColors.mainBackground,
//                      ),
//                    )
//                    ,
                    _logsCount),
                Spacer(),
                GpsInfoButton(_gpsStatusValueNotifier),
                Spacer(),
                IconButton(
                  onPressed: () {
                    setState(() {
                      if (_lastPosition != null)
                        _mapController.move(
                            LatLng(_lastPosition.latitude,
                                _lastPosition.longitude),
                            _mapController.zoom);
                    });
                  },
                  tooltip: 'Center on GPS',
                  icon: Icon(
                    Icons.center_focus_strong,
                    color: SmashColors.mainBackground,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      var zoom = _mapController.zoom + 1;
                      if (zoom > 19) zoom = 19;
                      _mapController.move(_mapController.center, zoom);
                    });
                  },
                  tooltip: 'Zoom in',
                  icon: Icon(
                    Icons.zoom_in,
                    color: SmashColors.mainBackground,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      var zoom = _mapController.zoom - 1;
                      if (zoom < 0) zoom = 0;
                      _mapController.move(_mapController.center, zoom);
                    });
                  },
                  tooltip: 'Zoom out',
                  icon: Icon(
                    Icons.zoom_out,
                    color: SmashColors.mainBackground,
                  ),
                ),
              ],
            ),
          ),
        ),
        onWillPop: () async {
          bool doExit = await showConfirmDialog(
              context,
              "Are you sure you want to exit?",
              "Active operations will be stopped.");
          if (doExit) {
            dispose();
            return Future.value(true);
          }
        });
  }

  Widget makeToolbarBadge(Widget widget, int badgeValue) {
    if (badgeValue > 0) {
      return Badge(
        badgeColor: SmashColors.mainSelection,
        shape: BadgeShape.circle,
        toAnimate: false,
        badgeContent: Text(
          '$badgeValue',
          style: TextStyle(color: Colors.white),
        ),
        child: widget,
      );
    } else {
      return widget;
    }
  }

  getEndDrawerWidgets(BuildContext context) {
    var c = SmashColors.mainDecorations;
    var textStyle = GpConstants.MEDIUM_DIALOG_TEXT_STYLE;
    var iconSize = GpConstants.MEDIUM_DIALOG_ICON_SIZE;
    return [
      new Container(
        margin: EdgeInsets.only(bottom: 20),
        child: new DrawerHeader(child: Image.asset("assets/maptools_icon.png")),
        color: SmashColors.mainBackground,
      ),
      new Container(
        child: new Column(children: [
          ListTile(
            leading: new Icon(
              Icons.navigation,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Go to",
              style: textStyle,
            ),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          GeocodingPage(_mapCenterValueNotifier)));
            },
          ),
          ListTile(
            leading: new Icon(
              Icons.share,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Share position",
              style: textStyle,
            ),
            onTap: () {},
          ),
          ListTile(
            leading: new Icon(
              Icons.layers,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Layers",
              style: textStyle,
            ),
            onTap: () => _openLayers(context),
          ),
          ListTile(
            leading: new Icon(
              Icons.center_focus_weak,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "GPS on screen",
              style: textStyle,
            ),
            trailing: Checkbox(
                value: _keepGpsOnScreenNotifier.value,
                onChanged: (value) {
                  _keepGpsOnScreenNotifier.value = value;
                  GpPreferences().setBoolean(KEY_CENTER_ON_GPS, value);
//                  Navigator.of(context).pop();
                }),
            onTap: () => _openLayers(context),
          ),
        ]),
      ),
    ];
  }

  _openLayers(BuildContext context) async {
    File file =
        await FilePicker.getFile(type: FileType.ANY, fileExtension: 'map');
    if (file != null) {
      if (file.path.endsWith(".map")) {
//                GeopaparazziMapLoader loader =
//                    new GeopaparazziMapLoader(file, this);
//                loader.loadNotes();
        _mapsforgeLayer = await loadMapsforgeLayer(file);
        await GpPreferences().setString(KEY_LAST_MAPSFORGEPATH, file.path);
        setState(() {});
      } else {
        showWarningDialog(context, "File format not supported.");
      }
    }
  }

  @override
  void dispose() {
    updateCenterPosition();
    GpsHandler().removePositionListener(this);
    if (gpProjectModel != null) {
      _savePosition().then((v) {
        gpProjectModel.close();
        gpProjectModel = null;
        super.dispose();
      });
    } else {
      super.dispose();
    }
  }

  void updateCenterPosition() {
    // save last position
    gpProjectModel.lastCenterLon = _mapController.center.longitude;
    gpProjectModel.lastCenterLat = _mapController.center.latitude;
    gpProjectModel.lastCenterZoom = _mapController.zoom;
  }

  Future<void> reloadProject() async {
    await loadCurrentProject();
    setState(() {});
  }

  Future<void> moveTo(LatLng position) async {
    _mapController.move(position, _mapController.zoom);
  }

  Future<void> _savePosition() async {
    await GpPreferences().setLastPosition(gpProjectModel.lastCenterLon,
        gpProjectModel.lastCenterLat, gpProjectModel.lastCenterZoom);
  }

  _openAddNoteFunction(context) {
    if (GpsHandler().hasFix()) {
      Navigator.push(
          context, MaterialPageRoute(builder: (context) => AddNotePage()));
    } else {
      showOperationNeedsGps(context);
    }
  }

  _getDrawerWidgets(BuildContext context) {
//    final String assetName = 'assets/geopaparazzi_launcher_icon.svg';
    double iconSize = 48;
    double textSize = iconSize / 2;
    var c = SmashColors.mainDecorations;
    return [
      new Container(
        margin: EdgeInsets.only(bottom: 20),
        child: new DrawerHeader(child: Image.asset("assets/smash_icon.png")),
        color: SmashColors.mainBackground,
      ),
      new Container(
        child: new Column(children: [
          ListTile(
            leading: new Icon(
              Icons.create_new_folder,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "New Project",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () => _createNewProject(context),
          ),
          ListTile(
            leading: new Icon(
              Icons.folder_open,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Open Project",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () => _openProject(context),
          ),
          ListTile(
            leading: new Icon(
              Icons.file_download,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Import",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () {},
          ),
          ListTile(
            leading: new Icon(
              Icons.file_upload,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Export",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () {},
          ),
          ListTile(
            leading: new Icon(
              Icons.settings,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "Settings",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () => _openSettings(context),
          ),
          ListTile(
            leading: new Icon(
              Icons.info_outline,
              color: c,
              size: iconSize,
            ),
            title: Text(
              "About",
              style: TextStyle(fontSize: textSize, color: c),
            ),
            onTap: () => _openAbout(context),
          ),
        ]),
      ),
    ];
  }

  Future doExit(BuildContext context) async {
    await gpProjectModel.close();

    await SystemChannels.platform.invokeMethod<void>('SystemNavigator.pop');
  }

  Future _openSettings(BuildContext context) async {}

  Future _openAbout(BuildContext context) async {}

  Future _openProject(BuildContext context) async {
    File file =
        await FilePicker.getFile(type: FileType.ANY, fileExtension: 'gpap');
    if (file != null && file.existsSync()) {
      gpProjectModel.setNewProject(this, file.path);
      reloadProject();
    }
    Navigator.of(context).pop();
  }

  Future _createNewProject(BuildContext context) async {
    String projectName =
        "geopaparazzi_${GpConstants.DATE_TS_FORMATTER.format(DateTime.now())}";

    var userString = await showInputDialog(
      context,
      "New Project",
      "Enter a name for the new project or accept the proposed.",
      hintText: '',
      defaultText: projectName,
      validationFunction: fileNameValidator,
    );
    if (userString != null) {
      if (userString.trim().length == 0) userString = projectName;
      var file = await FileUtils.getDefaultStorageFolder();
      var newPath = join(file.path, userString);
      if (!newPath.endsWith(".gpap")) {
        newPath = "$newPath.gpap";
      }
      var gpFile = new File(newPath);
      gpProjectModel.setNewProject(this, gpFile.path);
    }

    Navigator.of(context).pop();
  }

  @override
  void onPositionUpdate(Position position) {
    if (_keepGpsOnScreenNotifier.value &&
        !_mapController.bounds
            .contains(LatLng(position.latitude, position.longitude))) {
      _mapController.move(
          LatLng(position.latitude, position.longitude), _mapController.zoom);
    }
    setState(() {
      _lastPosition = position;
    });
  }

  @override
  void setStatus(GpsStatus currentStatus) {
    _gpsStatusValueNotifier.value = currentStatus;
  }

  loadCurrentProject() async {
    var db = await gpProjectModel.getDatabase();
    if (db == null) return;
    _projectName = basenameWithoutExtension(db.path);
    _projectDirName = dirname(db.path);
    _notesCount = await db.getNotesCount(false);
    _logsCount = await db.getGpsLogCount(false);

    List<Marker> tmp = [];
    // IMAGES
//    List<Map<String, dynamic>> resImages =
//        await db.query("images", columns: ['lat', 'lon']);
//    resImages.forEach((map) {
//      var lat = map["lat"];
//      var lon = map["lon"];
//      tmp.add(Marker(
//        width: 80.0,
//        height: 80.0,
//        point: new LatLng(lat, lon),
//        builder: (ctx) => new Container(
//              child: Icon(
//                Icons.image,
//                size: 32,
//                color: Colors.blue,
//              ),
//            ),
//      ));
//    });

    // NOTES
    List<Note> notesList = await db.getNotes(false);
    notesList.forEach((note) {
      var label =
          "note: ${note.text}\nlat: ${note.lat}\nlon: ${note.lon}\naltim: ${note.altim}\nts: ${GpConstants.ISO8601_TS_FORMATTER.format(DateTime.fromMillisecondsSinceEpoch(note.timeStamp))}";
      NoteExt noteExt = note.noteExt;
      tmp.add(Marker(
        width: 80,
        height: 80,
        point: new LatLng(note.lat, note.lon),
        builder: (ctx) => new Container(
                child: GestureDetector(
              onTap: () {
                _showSnackbar(SnackBar(
                  backgroundColor: SmashColors.snackBarColor,
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            label,
                            style: GpConstants.MEDIUM_DIALOG_TEXT_STYLE_NEUTRAL,
                            textAlign: TextAlign.start,
                          ),
                        ],
                      ),
                      Padding(
                        padding: EdgeInsets.only(top: 5),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            IconButton(
                              icon: Icon(
                                Icons.share,
                                color: SmashColors.mainSelection,
                              ),
                              iconSize: GpConstants.MEDIUM_DIALOG_ICON_SIZE,
                              onPressed: () {
                                shareText(label);
                                _hideSnackbar();
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.edit,
                                color: SmashColors.mainSelection,
                              ),
                              iconSize: GpConstants.MEDIUM_DIALOG_ICON_SIZE,
                              onPressed: () {
                                Navigator.push(
                                    ctx,
                                    MaterialPageRoute(
                                        builder: (context) =>
                                            NotePropertiesWidget(
                                                reloadProject, note)));
                                _hideSnackbar();
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete,
                                color: SmashColors.mainDanger,
                              ),
                              iconSize: GpConstants.MEDIUM_DIALOG_ICON_SIZE,
                              onPressed: () async {
                                var doRemove = await showConfirmDialog(
                                    ctx,
                                    "Remove Note",
                                    "Are you sure you want to remove note ${note.id}?");
                                if (doRemove) {
                                  var db = await gpProjectModel.getDatabase();
                                  db.deleteNote(note.id);
                                  reloadProject();
                                }
                                _hideSnackbar();
                              },
                            ),
                            Spacer(flex: 1),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                color: SmashColors.mainDecorationsDark,
                              ),
                              iconSize: GpConstants.MEDIUM_DIALOG_ICON_SIZE,
                              onPressed: () {
                                _hideSnackbar();
                              },
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                  duration: Duration(seconds: 5),
                ));
              },
              child: Icon(
                NOTES_ICONDATA[noteExt.marker],
                size: noteExt.size,
                color: ColorExt(noteExt.color),
              ),
            )),
      ));
    });

    String logsQuery = '''
        select l.$LOGS_COLUMN_ID, p.$LOGSPROP_COLUMN_COLOR, p.$LOGSPROP_COLUMN_WIDTH 
        from $TABLE_GPSLOGS l, $TABLE_GPSLOG_PROPERTIES p 
        where l.$LOGS_COLUMN_ID = p.$LOGSPROP_COLUMN_ID and p.$LOGSPROP_COLUMN_VISIBLE=1
    ''';

    List<Map<String, dynamic>> resLogs = await db.query(logsQuery);
    Map<int, List> logs = Map();
    resLogs.forEach((map) {
      var id = map['_id'];
      var color = map["color"];
      var width = map["width"];

      logs[id] = [color, width, <LatLng>[]];
    });

    addLogLines(tmp, logs, db);
  }

  void addLogLines(List<Marker> markers, Map<int, List> logs, var db) async {
    String logDataQuery =
        "select $LOGSDATA_COLUMN_LAT, $LOGSDATA_COLUMN_LON, $LOGSDATA_COLUMN_LOGID from $TABLE_GPSLOG_DATA order by $LOGSDATA_COLUMN_LOGID, $LOGSDATA_COLUMN_TS";
    List<Map<String, dynamic>> resLogs = await db.query(logDataQuery);
    resLogs.forEach((map) {
      var logid = map[LOGSDATA_COLUMN_LOGID];
      var log = logs[logid];
      if (log != null) {
        var lat = map[LOGSDATA_COLUMN_LAT];
        var lon = map[LOGSDATA_COLUMN_LON];
        var coordsList = log[2];
        coordsList.add(LatLng(lat, lon));
      }
    });

    List<Polyline> lines = [];
    logs.forEach((key, list) {
      var color = list[0];
      var width = list[1];
      var points = list[2];
      lines.add(
          Polyline(points: points, strokeWidth: width, color: ColorExt(color)));
    });

    _geopapLogs = PolylineLayerOptions(
      polylines: lines,
    );
    _geopapMarkers = markers;
  }
}

/// Class to hold the state of the GPS info button, updated by the gps state notifier.
///
class GpsInfoButton extends StatefulWidget {
  final ValueNotifier<GpsStatus> _gpsStatusValueNotifier;

  GpsInfoButton(this._gpsStatusValueNotifier);

  @override
  State<StatefulWidget> createState() =>
      GpsInfoButtonState(_gpsStatusValueNotifier);
}

class GpsInfoButtonState extends State<GpsInfoButton> {
  ValueNotifier<GpsStatus> _gpsStatusValueNotifier;
  GpsStatus _gpsStatus;

  GpsInfoButtonState(this._gpsStatusValueNotifier);

  @override
  void initState() {
    _gpsStatusValueNotifier.addListener(() {
      setState(() {
        _gpsStatus = _gpsStatusValueNotifier.value;
      });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
        icon: getGpsStatusIcon(_gpsStatus),
        tooltip: "Check GPS Information",
        onPressed: () {
          print("GPS info Pressed...");
        });
  }
}

/// Class to hold the state of the GPS info button, updated by the gps state notifier.
///
class LoggingButton extends StatefulWidget {
  final ValueNotifier<GpsStatus> _gpsStatusValueNotifier;
  Function _reloadFunction;
  Function _moveToFunction;

  LoggingButton(
      this._gpsStatusValueNotifier, this._reloadFunction, this._moveToFunction);

  @override
  State<StatefulWidget> createState() => LoggingButtonState(
      _gpsStatusValueNotifier, _reloadFunction, _moveToFunction);
}

class LoggingButtonState extends State<LoggingButton> {
  ValueNotifier<GpsStatus> _gpsStatusValueNotifier;
  GpsStatus _gpsStatus;
  Function _reloadFunction;
  Function _moveToFunction;

  LoggingButtonState(
      this._gpsStatusValueNotifier, this._reloadFunction, this._moveToFunction);

  @override
  void initState() {
    _gpsStatusValueNotifier.addListener(() {
      if (this.mounted)
        setState(() {
          _gpsStatus = _gpsStatusValueNotifier.value;
        });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      child: IconButton(
          icon: getLoggingIcon(_gpsStatus),
          onPressed: () {
            toggleLoggingFunction(context);
          }),
      onLongPress: () {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) =>
                    LogListWidget(_reloadFunction, _moveToFunction)));
      },
    );
  }

  toggleLoggingFunction(BuildContext context) async {
    if (GpsHandler().isLogging) {
      await GpsHandler().stopLogging();
      _reloadFunction();
    } else {
      if (GpsHandler().hasFix()) {
        String logName =
            "log ${GpConstants.ISO8601_TS_FORMATTER.format(DateTime.now())}";

        String userString = await showInputDialog(
          context,
          "New Log",
          "Enter a name for the new log",
          hintText: '',
          defaultText: logName,
          validationFunction: noEmptyValidator,
        );

        if (userString != null) {
          if (userString.trim().length == 0) userString = logName;
          int logId = await GpsHandler().startLogging(logName);
          if (logId == null) {
            // TODO show error
          }
        }
      } else {
        showOperationNeedsGps(context);
      }
    }
  }
}

Icon getGpsStatusIcon(GpsStatus status) {
  Color color;
  IconData iconData;
  switch (status) {
    case GpsStatus.OFF:
      {
        color = SmashColors.gpsOff;
        iconData = Icons.gps_off;
        break;
      }
    case GpsStatus.ON_WITH_FIX:
      {
        color = SmashColors.gpsOnWithFix;
        iconData = Icons.gps_fixed;
        break;
      }
    case GpsStatus.ON_NO_FIX:
      {
        iconData = Icons.gps_not_fixed;
        color = SmashColors.gpsOnNoFix;
        break;
      }
    case GpsStatus.LOGGING:
      {
        iconData = Icons.gps_fixed;
        color = SmashColors.gpsLogging;
        break;
      }
    case GpsStatus.NOPERMISSION:
      {
        iconData = Icons.gps_off;
        color = SmashColors.gpsNoPermission;
        break;
      }
  }
  return Icon(
    iconData,
    color: color,
  );
}

Icon getLoggingIcon(GpsStatus status) {
  Color color;
  IconData iconData;
  switch (status) {
    case GpsStatus.LOGGING:
      {
        iconData = Icons.timeline;
        color = SmashColors.gpsLogging;
        break;
      }
    case GpsStatus.OFF:
    case GpsStatus.ON_WITH_FIX:
    case GpsStatus.ON_NO_FIX:
    case GpsStatus.NOPERMISSION:
      {
        iconData = Icons.timeline;
        color = SmashColors.mainBackground;
        break;
      }
    default:
      {
        iconData = Icons.timeline;
        color = SmashColors.mainBackground;
      }
  }
  return Icon(
    iconData,
    color: color,
  );
}

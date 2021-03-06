/*
 * Copyright (c) 2019-2020. Antonello Andrea (www.hydrologis.com). All rights reserved.
 * Use of this source code is governed by a GPL3 license that can be
 * found in the LICENSE file.
 */

import 'dart:core';

import 'package:dart_jts/dart_jts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_geopackage/flutter_geopackage.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/shapefile.dart';
import 'package:smashlibs/smashlibs.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/core/layermanager.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/core/layersource.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/core/onlinesourcespage.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/geopackage.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/gpx.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/tiles.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/wms.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/types/worldimage.dart';
import 'package:smash/eu/hydrologis/smash/models/map_state.dart';

class LayersPage extends StatefulWidget {
  LayersPage();

  @override
  State<StatefulWidget> createState() => LayersPageState();
}

class LayersPageState extends State<LayersPage> {
  bool _somethingChanged = false;

  @override
  Widget build(BuildContext context) {
    List<LayerSource> _layersList =
        LayerManager().getLayerSources(onlyActive: false);

    List<Widget> listItems = createLayersList(_layersList, context);

    return WillPopScope(
        onWillPop: () async {
          if (_somethingChanged) {
            setLayersOnChange(_layersList);
          }
          return true;
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text("Layer List"),
            actions: <Widget>[
              IconButton(
                icon: Icon(MdiIcons.earth),
                onPressed: () async {
                  var wmsLayerSource = await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => OnlineSourcesPage()));

                  if (wmsLayerSource != null) {
                    LayerManager().addLayerSource(wmsLayerSource);
                    setState(() {});
                  }
                },
                tooltip: "Load online sources",
              ),
              IconButton(
                icon: Icon(MdiIcons.map),
                onPressed: () async {
                  //Navigator.of(context).pop();
                  var lastUsedFolder = await Workspace.getLastUsedFolder();
                  var allowed = <String>[]
                    ..addAll(FileManager.ALLOWED_VECTOR_DATA_EXT)
                    ..addAll(FileManager.ALLOWED_RASTER_DATA_EXT)
                    ..addAll(FileManager.ALLOWED_TILE_DATA_EXT);
                  var selectedPath = await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) =>
                              FileBrowser(false, allowed, lastUsedFolder)));

                  if (selectedPath != null) {
                    await loadLayer(context, selectedPath);
                    setState(() {});
                  }
                },
                tooltip: "Load local datasets",
              ),
            ],
          ),
          body: ReorderableListView(
            children: listItems,
            onReorder: (oldIndex, newIndex) {
              if (oldIndex != newIndex) {
                setState(() {
                  LayerManager().moveLayer(oldIndex, newIndex);
                  _somethingChanged = true;
                });
              }
            },
          ),
        ));
  }

  List<Widget> createLayersList(
      List<LayerSource> _layersList, BuildContext context) {
    return _layersList.map((layerSourceItem) {
      var srid = layerSourceItem.getSrid();
      bool prjSupported;
      if (srid != null) {
        var projection = SmashPrj.fromSrid(srid);
        prjSupported = projection != null;
      }

      List<Widget> actions = [];
      List<Widget> secondaryActions = [];

      if (layerSourceItem.isZoomable()) {
        actions.add(IconSlideAction(
            caption: 'Zoom to',
            color: SmashColors.mainDecorations,
            icon: MdiIcons.magnifyScan,
            onTap: () async {
              LatLngBounds bb = await layerSourceItem.getBounds();
              if (bb != null) {
                setLayersOnChange(_layersList);

                SmashMapState mapState =
                    Provider.of<SmashMapState>(context, listen: false);
                mapState.setBounds(
                    new Envelope(bb.west, bb.east, bb.south, bb.north));
                Navigator.of(context).pop();
              }
            }));
      }
      if (layerSourceItem.hasProperties()) {
        actions.add(IconSlideAction(
            caption: 'Properties',
            color: SmashColors.mainDecorations,
            icon: MdiIcons.palette,
            onTap: () async {
              if (layerSourceItem is GpxSource) {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            GpxPropertiesWidget(layerSourceItem)));
                // } else if (layerSourceItem is ShapefileSource) {
                //   await Navigator.push(
                //       context,
                //       MaterialPageRoute(
                //           builder: (context) =>
                //               ShpPropertiesWidget(layerSourceItem)));
              } else if (layerSourceItem is WorldImageSource) {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            TiffPropertiesWidget(layerSourceItem)));
              } else if (layerSourceItem is WmsSource) {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            WmsPropertiesWidget(layerSourceItem)));
              } else if (layerSourceItem is TileSource) {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            TileSourcePropertiesWidget(layerSourceItem)));
              }
            }));
      }
      secondaryActions.add(IconSlideAction(
          caption: 'Delete',
          color: SmashColors.mainDanger,
          icon: MdiIcons.delete,
          onTap: () {
            if (layerSourceItem.isActive()) {
              _somethingChanged = true;
            }
            _layersList.remove(layerSourceItem);
            LayerManager().removeLayerSource(layerSourceItem);
            setState(() {});
          }));

      return Slidable(
        key: ValueKey(layerSourceItem),
        actionPane: SlidableDrawerActionPane(),
        actionExtentRatio: 0.25,
        child: ListTile(
          title: SingleChildScrollView(
            child: Text('${layerSourceItem.getName()}'),
            scrollDirection: Axis.horizontal,
          ),
          subtitle: prjSupported == null
              ? Text(
                  "The proj could not be recognised. Will try to load anyway.",
                  style: TextStyle(color: SmashColors.mainDanger),
                )
              : prjSupported
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                          'EPSG:$srid ${layerSourceItem.getAttribution()}'),
                    )
                  : Text(
                      "The proj is not supported. Tap to solve.",
                      style: TextStyle(color: SmashColors.mainDanger),
                    ),
          onTap: () {
            if (!prjSupported) {
              // showWarningDialog(context, "Need to add prj: $srid");

              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => ProjectionsSettings(
                            epsgToDownload: srid,
                          )));
            }
          },
          leading: Icon(
            SmashIcons.forPath(
                layerSourceItem.getAbsolutePath() ?? layerSourceItem.getUrl()),
            color: SmashColors.mainDecorations,
            size: SmashUI.MEDIUM_ICON_SIZE,
          ),
          trailing: Checkbox(
              value: layerSourceItem.isActive(),
              onChanged: (isVisible) async {
                layerSourceItem.setActive(isVisible);
                _somethingChanged = true;
                setState(() {});
              }),
        ),
        actions: actions,
        secondaryActions: secondaryActions,
      );
    }).toList();
  }

  void setLayersOnChange(List<LayerSource> _layersList) {
    List<String> layers = _layersList.map((ls) => ls.toJson()).toList();
    GpPreferences().setLayerInfoList(layers);
  }
}

Future<bool> loadLayer(BuildContext context, String filePath) async {
  if (FileManager.isMapsforge(filePath)) {
    TileSource ts = TileSource.Mapsforge(filePath);
    LayerManager().addLayerSource(ts);
    return true;
  } else if (FileManager.isMbtiles(filePath)) {
    TileSource ts = TileSource.Mbtiles(filePath);
    LayerManager().addLayerSource(ts);
    return true;
  } else if (FileManager.isMapurl(filePath)) {
    TileSource ts = TileSource.Mapurl(filePath);
    LayerManager().addLayerSource(ts);
    return true;
  } else if (FileManager.isGpx(filePath)) {
    GpxSource gpxLayer = GpxSource(filePath);
    await gpxLayer.load(context);
    if (gpxLayer.hasData()) {
      LayerManager().addLayerSource(gpxLayer);
      return true;
    }
  } else if (FileManager.isShp(filePath)) {
    ShapefileSource shpLayer = ShapefileSource(filePath);
    await shpLayer.load(context);
    if (shpLayer.hasData()) {
      LayerManager().addLayerSource(shpLayer);
      return true;
    }
  } else if (FileManager.isWorldImage(filePath)) {
    var worldFile = WorldImageSource.getWorldFile(filePath);
    var prjFile = SmashPrj.getPrjForImage(filePath);
    if (worldFile == null) {
      showWarningDialog(context,
          "Only image files with world file definition are supported.");
    } else if (prjFile == null) {
      showWarningDialog(
          context, "Only image files with prj file definition are supported.");
    } else {
      WorldImageSource worldLayer = WorldImageSource(filePath);
      // await worldLayer.load(context);
      if (worldLayer.hasData()) {
        LayerManager().addLayerSource(worldLayer);
        return true;
      }
    }
  } else if (FileManager.isGeopackage(filePath)) {
    var ch = ConnectionsHandler();
    try {
      var db = ch.open(filePath);
      List<FeatureEntry> features = db.features();
      for (var f in features) {
        GeopackageSource gps = GeopackageSource(filePath, f.tableName);
        gps.calculateSrid();
        LayerManager().addLayerSource(gps);
      }

      List<TileEntry> tiles = db.tiles();
      tiles.forEach((t) {
        var ts = TileSource.Geopackage(filePath, t.tableName);
        LayerManager().addLayerSource(ts);
        return true;
      });
    } finally {
      ch?.close(filePath);
    }
  } else {
    showWarningDialog(context, "File format not supported.");
  }
  return false;
}

/*
 * Copyright (c) 2019-2020. Antonello Andrea (www.hydrologis.com). All rights reserved.
 * Use of this source code is governed by a GPL3 license that can be
 * found in the LICENSE file.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:after_layout/after_layout.dart';
import 'package:dart_hydrologis_db/dart_hydrologis_db.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:dart_hydrologis_utils/dart_hydrologis_utils.dart';
import 'package:smashlibs/com/hydrologis/flutterlibs/utils/logging.dart';
import 'package:smashlibs/smashlibs.dart';
import 'package:smash/eu/hydrologis/smash/gss/gss_utilities.dart';

class GssImportWidget extends StatefulWidget {
  GssImportWidget({Key key}) : super(key: key);

  @override
  _GssImportWidgetState createState() => new _GssImportWidgetState();
}

class _GssImportWidgetState extends State<GssImportWidget>
    with AfterLayoutMixin {
  /*
   * 0 = waiting
   * 1 = has data
   *
   * 10 = no server pwd available
   * 11 = no server url available
   * 12 = download list error
   * 13 = permission denied error
   */
  int _status = 0;

  String _mapsFolderPath;
  String _projectsFolderPath;
  String _formsFolderPath;
  String _serverUrl;
  String _authHeader;
  List<String> _baseMapsList = [];
  List<String> _projectsList = [];
  List<String> _tagsList = [];

  @override
  void afterFirstLayout(BuildContext context) {
    init();
  }

  Future<void> init() async {
    Directory mapsFolder = await Workspace.getMapsFolder();
    _mapsFolderPath = mapsFolder.path;
    Directory projectsFolder = await Workspace.getProjectsFolder();
    _projectsFolderPath = projectsFolder.path;
    Directory formsFolder = await Workspace.getFormsFolder();
    _formsFolderPath = formsFolder.path;

    _serverUrl = GpPreferences().getStringSync(KEY_GSS_SERVER_URL);
    if (_serverUrl == null) {
      setState(() {
        _status = 11;
      });
      return;
    }
    String downloadDataListUrl = _serverUrl + GssUtilities.DATA_DOWNLOAD_PATH;
    String downloadTagsListUrl = _serverUrl + GssUtilities.TAGS_DOWNLOAD_PATH;

    String pwd = GpPreferences().getStringSync(KEY_GSS_SERVER_PWD);
    if (pwd == null || pwd.trim().isEmpty) {
      setState(() {
        _status = 10;
      });
      return;
    }
    _authHeader = await GssUtilities.getAuthHeader(pwd);

    try {
      Dio dio = NetworkHelper.getNewDioInstance();

      var dataResponse = await dio.get(downloadDataListUrl,
          options: Options(headers: {"Authorization": _authHeader}));
      var dataResponseMap = jsonDecode(dataResponse.data);

      List<dynamic> baseMaps = dataResponseMap[GssUtilities.DATA_DOWNLOAD_MAPS];
      _baseMapsList.clear();
      baseMaps.forEach((bm) {
        var name = bm[GssUtilities.DATA_DOWNLOAD_NAME];
        if (FileManager.isVectordataFile(name) ||
            FileManager.isTiledataFile(name)) {
          _baseMapsList.add(name);
        }
      });

      List<dynamic> _projects =
          dataResponseMap[GssUtilities.DATA_DOWNLOAD_PROJECTS];
      _projectsList.clear();
      _projects.forEach((proj) {
        var name = proj[GssUtilities.DATA_DOWNLOAD_NAME];
        if (FileManager.isProjectFile(name)) {
          _projectsList.add(name);
        }
      });

      var tagsResponse = await dio.get(downloadTagsListUrl,
          options: Options(headers: {"Authorization": _authHeader}));
      var tagsResponseMap = jsonDecode(tagsResponse.data);
      var tagsJsonList = tagsResponseMap[GssUtilities.TAGS_DOWNLOAD_TAGS];
      if (tagsJsonList != null) {
        tagsJsonList.forEach((tg) {
          var name = tg[GssUtilities.TAGS_DOWNLOAD_TAG];
          _tagsList.add(name);
        });
      }

      setState(() {
        _status = 1;
      });
    } catch (e, s) {
      if (e is DioError) {
        var code = e.response.statusCode;
        var msg = e.response.statusMessage;
        if (code == 403) {
          setState(() {
            _status = 13;
          });
        } else {
          SMLogger().e(msg, s);
        }
      } else {
        print(e);
        setState(() {
          _status = 12;
        });
        SMLogger().e("An error occurred while downloading GSS data list.", s);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // make sure new tags are read
        await TagsManager().readFileTags();
        return true;
      },
      child: new Scaffold(
        appBar: new AppBar(
          title: new Text("GSS Import"),
        ),
        body: _status == 0
            ? Center(
                child: SmashCircularProgress(label: "Downloading data list..."),
              )
            : _status == 12
                ? Center(
                    child: Padding(
                      padding: SmashUI.defaultPadding(),
                      child: SmashUI.errorWidget(
                          "Unable to download data list due to an error. Check your settings and the log."),
                    ),
                  )
                : _status == 11
                    ? Center(
                        child: Padding(
                          padding: SmashUI.defaultPadding(),
                          child: SmashUI.titleText(
                              "No GSS server url has been set. Check your settings."),
                        ),
                      )
                    : _status == 10
                        ? Center(
                            child: Padding(
                              padding: SmashUI.defaultPadding(),
                              child: SmashUI.titleText(
                                  "No GSS server password has been set. Check your settings."),
                            ),
                          )
                        : _status == 13
                            ? Center(
                                child: Padding(
                                  padding: SmashUI.defaultPadding(),
                                  child: SmashUI.errorWidget(
                                      "No permission to access the server. Check your credentials."),
                                ),
                              )
                            : SingleChildScrollView(
                                child: Column(
                                  children: <Widget>[
                                    Container(
                                      width: double.infinity,
                                      child: Card(
                                        margin: SmashUI.defaultMargin(),
                                        elevation: SmashUI.DEFAULT_ELEVATION,
                                        color: SmashColors.mainBackground,
                                        child: Column(
                                          children: <Widget>[
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.normalText("Data",
                                                  bold: true),
                                            ),
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.smallText(
                                                  _baseMapsList.length > 0
                                                      ? "Datasets are downloaded into the maps folder."
                                                      : "No data available.",
                                                  color: Colors.grey),
                                            ),
                                            ListView.builder(
                                              shrinkWrap: true,
                                              itemCount: _baseMapsList.length,
                                              itemBuilder: (context, index) {
                                                var name = _baseMapsList[index];

                                                String downloadUrl = _serverUrl +
                                                    GssUtilities
                                                        .DATA_DOWNLOAD_PATH +
                                                    "?" +
                                                    GssUtilities
                                                        .DATA_DOWNLOAD_NAME +
                                                    "=" +
                                                    name;

                                                return FileDownloadListTileProgressWidget(
                                                  downloadUrl,
                                                  FileUtilities.joinPaths(
                                                      _mapsFolderPath, name),
                                                  name,
                                                  authHeader: _authHeader,
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: double.infinity,
                                      child: Card(
                                        margin: SmashUI.defaultMargin(),
                                        elevation: SmashUI.DEFAULT_ELEVATION,
                                        color: SmashColors.mainBackground,
                                        child: Column(
                                          children: <Widget>[
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.normalText(
                                                  "Projects",
                                                  bold: true),
                                            ),
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.smallText(
                                                  _projectsList.length > 0
                                                      ? "Projects are downloaded into the projects folder."
                                                      : "No projects available.",
                                                  color: Colors.grey),
                                            ),
                                            ListView.builder(
                                              shrinkWrap: true,
                                              itemCount: _projectsList.length,
                                              itemBuilder: (context, index) {
                                                var name = _projectsList[index];

                                                String downloadUrl = _serverUrl +
                                                    GssUtilities
                                                        .DATA_DOWNLOAD_PATH +
                                                    "?" +
                                                    GssUtilities
                                                        .DATA_DOWNLOAD_NAME +
                                                    "=" +
                                                    name;

                                                return FileDownloadListTileProgressWidget(
                                                  downloadUrl,
                                                  FileUtilities.joinPaths(
                                                      _projectsFolderPath,
                                                      name),
                                                  name,
                                                  authHeader: _authHeader,
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: double.infinity,
                                      child: Card(
                                        margin: SmashUI.defaultMargin(),
                                        elevation: SmashUI.DEFAULT_ELEVATION,
                                        color: SmashColors.mainBackground,
                                        child: Column(
                                          children: <Widget>[
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.normalText("Forms",
                                                  bold: true),
                                            ),
                                            Padding(
                                              padding: SmashUI.defaultPadding(),
                                              child: SmashUI.smallText(
                                                  _tagsList.length > 0
                                                      ? "Tags files are downloaded into the forms folder."
                                                      : "No tags available.",
                                                  color: Colors.grey),
                                            ),
                                            ListView.builder(
                                              shrinkWrap: true,
                                              itemCount: _tagsList.length,
                                              itemBuilder: (context, index) {
                                                var name = _tagsList[index];

                                                String downloadUrl =
                                                    _serverUrl +
                                                        GssUtilities
                                                            .TAGS_DOWNLOAD_PATH +
                                                        // "/" +
                                                        "?" +
                                                        GssUtilities
                                                            .TAGS_DOWNLOAD_NAME +
                                                        "=" +
                                                        name;

                                                return FileDownloadListTileProgressWidget(
                                                  downloadUrl,
                                                  FileUtilities.joinPaths(
                                                      _formsFolderPath, name),
                                                  name,
                                                  authHeader: _authHeader,
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
      ),
    );
  }
}

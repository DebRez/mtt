# -*- coding: utf-8; tab-width: 4; indent-tabs-mode: f; python-indent: 4 -*-
#
# Copyright (c) 2015-2019 Intel, Inc.  All rights reserved.
# Copyright (c) 2017-2018 Los Alamos National Security, LLC. All rights
#                         reserved.
# $COPYRIGHT$
#
# Additional copyrights may follow
#
# $HEADER$
#

from __future__ import print_function
from future import standard_library
standard_library.install_aliases()
import os
from urllib.parse import urlparse
from FetchMTTTool import *
from distutils.spawn import find_executable
import sys
import shutil

## @addtogroup Tools
# @{
# @addtogroup Fetch
# @section FetchRPM
# Plugin for fetching and locally installing rpms from the Web
# @param rpm        rpm name (can be local file)
# @param url        URL to where the rpm can be found if other than repository
# @param query      Command to use to query pre-existing installation
# @param install    Command to use to install the package
# @param sudo       Superuser authority required
# @}
class FetchRPM(FetchMTTTool):

    def __init__(self):
        # initialise parent class
        FetchMTTTool.__init__(self)
        self.activated = False
        # track the repos we have processed so we
        # don't do them multiple times
        self.done = {}
        self.options = {}
        self.options['rpm'] = (None, "rpm name - can be local file")
        self.options['query'] = ("rpm -q", "Command to use to query pre-existing installation")
        self.options['install'] = ("rpm -i", "Command to use to install the package")
        self.options['sudo'] = (False, "Superuser authority required")
        return

    def activate(self):
        if not self.activated:
            # use the automatic procedure from IPlugin
            IPlugin.activate(self)
        return

    def deactivate(self):
        IPlugin.deactivate(self)
        return

    def print_name(self):
        return "FetchRPM"

    def print_options(self, testDef, prefix):
        lines = testDef.printOptions(self.options)
        for line in lines:
            print(prefix + line)
        return

    def execute(self, log, keyvals, testDef):
        testDef.logger.verbose_print("FetchRPM Execute")
        # parse any provided options - these will override the defaults
        cmds = {}
        testDef.parseOptions(log, self.options, keyvals, cmds)
        # check that they gave us an rpm namne
        try:
            if cmds['rpm'] is not None:
                rpm = cmds['rpm']
        except KeyError:
            log['status'] = 1
            log['stderr'] = "No RPM was provided"
            return
        testDef.logger.verbose_print("Download rpm " + rpm)
        # check to see if we have already processed this rpm
        try:
            if self.done[rpm] is not None:
                log['status'] = self.done[rpm]
                log['stdout'] = "RPM " + rpm + " has already been processed"
                return
        except KeyError:
            pass

        # look for the executable in our path - this is
        # a standard system executable so we don't use
        # environmental modules here
        basecmd = cmds['query'].split(' ',1)[0]
        if not find_executable(basecmd):
            log['status'] = 1
            log['stderr'] = "Executable " + basecmd + " not found"
            return

        # see if the rpm has already been installed on the system
        testDef.logger.verbose_print("checking system for rpm: " + rpm)
        qcmd = []
        if cmds['sudo']:
            qcmd.append("sudo")
        tmp = cmds['query'].split()
        for t in tmp:
            qcmd.append(t)
        qcmd.append(rpm)
        results = testDef.execmd.execute(None, qcmd, testDef)
        if 0 == results['status']:
            log['status'] = 0
            log['stdout'] = "RPM " + rpm + " already exists on system"
            return

        # setup to install
        icmd = []
        if cmds['sudo']:
            icmd.append("sudo")
        tmp = cmds['install'].split()
        for t in tmp:
            icmd.append(t)
        icmd.append(rpm)
        testDef.logger.verbose_print("installing package " + rpm)
        results = testDef.execmd.execute(None, icmd, testDef)
        if 0 != results['status']:
            log['status'] = 1
            log['stderr'] = "install of " + rpm + " FAILED"
            return

        # record the result
        log['status'] = results['status']
        log['stdout'] = results['stdout']
        log['stderr'] = results['stderr']

        # track that we serviced this one
        self.done[rpm] = results['status']
        return

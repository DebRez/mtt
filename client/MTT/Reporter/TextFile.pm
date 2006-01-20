#!/usr/bin/env perl
#
# Copyright (c) 2005-2006 The Trustees of Indiana University.
#                         All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::Reporter::TextFile;

use strict;
use Cwd;
use POSIX qw(strftime);
use MTT::Messages;
use MTT::Values;
use MTT::Files;
use Data::Dumper;

# directory and file to write to
my $dirname;
my $filename;

# separator between entries in the file
my $sep;

# files we've written to already in this run
my $written_files;

#--------------------------------------------------------------------------

sub Init {
    my ($ini, $section) = @_;

    # Extract data from the ini fields

    $filename = Value($ini, $section, "file");
    if (!$filename) {
        Warning("Not enough information in File Reporter section [$section]; must have filename; skipping this section");
        return undef;
    }
    $sep = Value($ini, $section, "separator");
    $sep = "============================================================================"
        if (!$sep);

    # Make it an absolute filename, because there's oodles of
    # chdir()'s within the testing.  Whack the file if it's already
    # there.

    if ($filename ne "-") {
        if ($filename !~ /\//) {
            $dirname = cwd();
            $filename = "$filename";
        } else {
            $dirname = dirname($filename);
            $filename = basename($filename);
        }
        Debug("File reporter initialized ($dirname/$filename)\n");
    } else {
        Debug("File reporter initialized (<stdout>)\n");
    }

    1;
}

#--------------------------------------------------------------------------

sub Submit {
    my ($info, $entries) = @_;

    Debug("File reporter\n");

    foreach my $entry (@$entries) {
        my $phase = $entry->{phase};
        my $section = $entry->{section};
        my $report = $entry->{report};

        my $str = MTT::Reporter::MakeReportString($report);

        # Substitute in the filename

        my $date = strftime("%m%d%Y", localtime);
        my $time = strftime("%H%M%S", localtime);
        my $mpi_name = $report->{mpi_name} ? $report->{mpi_name} : "Unknown-MPI";
        my $mpi_section = $report->{mpi_section_name} ? $report->{mpi_section_name} : "Unknown-MPI-section";
        my $mpi_version = $report->{mpi_version} ? $report->{mpi_version} : "Unknown-MPI-Version";
        my $file;
        my $e = "\$file = MTT::Files::make_safe_filename(\"$filename\");";
        eval $e;
        $file = "$dirname/$file";
        Debug("Writing to text file: $file\n");

        # If we have not yet written to the file in this run, then
        # whack the file.

        my $want_sep = 1;
        if (!exists($written_files->{$file})) {
            unlink($file);
            $want_sep = 0;
        }

        # Write to stdout or append to the file

        if ($file eq "-") {
            print "$sep\n"
                if ($want_sep);
            print $str;
            Verbose(">> Reported to stdout\n")
                if (!exists($written_files->{$file}));
        } else {
            open(OUT, ">>$file");
            print OUT "$sep\n"
                if ($want_sep);
            print OUT $str;
            close(OUT);
            Verbose(">> Reported to text file $file\n")
                if (!exists($written_files->{$file}));
        }
        $written_files->{$file} = 1;
    }
}

1;

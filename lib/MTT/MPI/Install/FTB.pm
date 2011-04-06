#!/usr/bin/env perl
#
# Copyright (c) 2005-2011 The Trustees of Indiana University.
#                         All rights reserved.
# Copyright (c) 2006-2008 Cisco Systems, Inc.  All rights reserved.
# Copyright (c) 2009      High Performance Computing Center Stuttgart, 
#                         University of Stuttgart.  All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::MPI::Install::FTB;

use strict;
use Data::Dumper;
use MTT::DoCommand;
use MTT::Messages;
use MTT::FindProgram;
use MTT::Values;
use MTT::Files;
use MTT::Common::GNU_Install;
use MTT::Common::Cmake;

#--------------------------------------------------------------------------

sub Install {
    my ($ini, $section, $config) = @_;
    my $x;
    my $result_stdout;
    my $result_stderr;

    # Prepare $ret

    my $ret;
    $ret->{test_result} = MTT::Values::FAIL;
    $ret->{exit_status} = 0;
    $ret->{installdir} = $config->{installdir};
    $ret->{bindir} = "$ret->{installdir}/sbin";
    $ret->{libdir} = "$ret->{installdir}/lib";

    # Get some FTB-module-specific config arguments

    my $tmp;
    $tmp = Value($ini, $section, "ftb_make_all_arguments");
    $config->{make_all_arguments} = $tmp
        if (defined($tmp));

    # JMS: compiler name may have come in from "compiler_name"in
    # Install.pm.  So if we didn't define one for this module, use the
    # default from "compiler_name".  Note: to be deleted someday
    # (i.e., only rely on this module's compiler_name and not use a
    # higher-level default, per #222).
    $tmp = Value($ini, $section, "ftb_compiler_name");
    $config->{compiler_name} = $tmp
        if (defined($tmp));
    return 
        if (!MTT::Util::is_valid_compiler_name($section, 
                                               $config->{compiler_name}));
    # JMS: Same as above
    $tmp = Value($ini, $section, "ftb_compiler_version");
    $config->{compiler_version} = $tmp
        if (defined($tmp));

    $tmp = Value($ini, $section, "ftb_configure_arguments");
    $tmp =~ s/\n|\r/ /g;
    $config->{configure_arguments} = $tmp
        if (defined($tmp));

    $tmp = Logical($ini, $section, "ftb_make_check");
    $config->{make_check} = $tmp
        if (defined($tmp));

    # Run configure / make all / make check / make install

    my $gnu = {
        configdir => $config->{configdir},
        configure_arguments => $config->{configure_arguments},
        compiler_name => $config->{compiler_name},
        vpath => "no",
        installdir => $config->{installdir},
        bindir => $config->{bindir},
        libdir => $config->{libdir},
        make_all_arguments => $config->{make_all_arguments},
        make_check => $config->{make_check},
        stdout_save_lines => $config->{stdout_save_lines},
        stderr_save_lines => $config->{stderr_save_lines},
        merge_stdout_stderr => $config->{merge_stdout_stderr},
    };

    my $install;
    if (MTT::Util::is_running_on_windows() && $config->{compiler_name} eq "microsoft") {
        $install = MTT::Common::Cmake::Install($gnu);
    } else {
        $install = MTT::Common::GNU_Install::Install($gnu);
    }

    foreach my $k (keys(%{$install})) {
        $ret->{$k} = $install->{$k};
    }
    return $ret
        if (exists($ret->{fail}));
    
    # Write out the FTB test run script.
    if ((0 != write_test_run_script("$ret->{bindir}")) 
        and (! $MTT::DoCommand::no_execute)) {
        $ret->{test_result} = MTT::Values::FAIL;
        $ret->{exit_status} = $x->{exit_status};
        $ret->{message} = "Failed to create test run script!";
        return $ret;
    }

    $ret->{test_result} = MTT::Values::PASS;
    $ret->{result_message} = "Success";
    $ret->{exit_status} = $x->{exit_status};
    Debug("Build was a success\n");
    return $ret;
}

# Write out the script that sets up the FTB and runs a given test
sub write_test_run_script {
    my $bindir = shift;
    my $file = "$bindir/run-ftb-test.pl";
    unlink($file);

    # Create the script and be paranoid about the permissions.

    my $u = umask;
    umask(0777);
    if (!open(FILE, ">$file")) {
        umask($u);
        return 1;
    }
    chmod(0755, $file);
    print FILE '#!/usr/bin/env perl
    
# This script is automatically generated by MTT/MPI/Install/FTB.pm.  
# Manual edits will be lost.

# Helper cleanup script spawn the FTB and run a given FTB test.

use strict;
use Class::Struct;
use Env qw(HOME PATH USER);
use POSIX;
use Socket;
use File::Basename;

# Perform flush after each write to STDOUT
$| = 1;

# Some tags
my $ERROR   = 0;
my $SUCCESS = 1;
my $INFO    = 2;
my $TIMED   = 3;
my $TRUE    = 123;
my $FALSE   = 987;

my $SKIP_TEST_EXIT_VALUE = 777;

my $drop_stdout       = "2> /dev/null 1>/dev/null";

my $exit_status = 0;
my $verbose;
my $rtn;
my $test_name;
my $test_path = "";

my $ftb_bstrap_server = "ftb_bootstrap_server";
my $ftb_agent = "ftb_agent";
my $launcher = "orted";

#
# Default NP argument
#
my $global_np_arg = "4";

#
# Stage Timers
#
my %timer_start_val = ();
my %timer_end_val = ();

my $ftb_bstrap_pid = 0;
my $ftb_agent_pid = 0;
my $test_child_pid = 0;

my $timeout_total = 0;
my $timeout_test = 0;

my $verbose;

#
# Parse the arguments
#
if( 0 != parse_args() ) {
  print_usage();
  exit -1;
}

print_verbose(1, "Running FTB test on $global_np_arg nodes.\n");

#
# Start the FTB Bootstrap Server on one node
#
print_banner("Start the FTB Bootstrap Server");
if( 0 != start_ftb_bstrap_server() ) {
  print_result($ERROR, "Unable to start [$ftb_bstrap_server]\n");
  $exit_status = -1;
}

# Wait for the FTB to wire up before firing the test
sleep(5);

#
# Start the FTB agents on all the allocated nodes
#
print_banner("Start the FTB agents");
if( 0 != start_ftb_agents() ) {
  print_result($ERROR, "Unable to start ftb_agent\n");
  $exit_status = -1;
}

# Wait for the FTB to wire up before firing the test
sleep(5);

#
# Start the test
#
print_banner("Starting the test [$test_name]");
if( 0 != start_test() ) {
  print_result($ERROR, "Unable to start the test [$test_name]\n");
  $exit_status = -1;
  goto CLEANUP;
}

#
# Determine the test PID
# Note: Should not execute unless fork didn\'t give us a point to watch.
#
if( 0 >= $test_child_pid ) {
  print_banner("Detect PID of the test [$test_name]");
  if( 0 != find_test_pid() ) {
    print_result($ERROR, "Unable to find the PID of the test [$test_name]\n");
    $exit_status = -2;
    goto CLEANUP;
  }
}

#
# Make sure test_child is not running any more
#
if( 0 < $test_child_pid ) {
  $rtn = wait_child($test_child_pid, $timeout_test);
  $test_child_pid = 0;
  if( $rtn != 0 ) {
    print_result($ERROR, "Test Run Child Finished with non-zero exit status [$rtn]\n");
    $exit_status = -1;
    goto CLEANUP;
  }
  else {
    print_verbose(2, "Test Run Child Finished (".$rtn.")\n");
  }
}

#
# Cleanup checkpoint related data
#
CLEANUP:
print_banner("Cleanup Environment");
if( 0 > post_cleanup() ) {
  print_result($ERROR, "Failed to cleanup properly\n");
  if( $exit_status != $SKIP_TEST_EXIT_VALUE ) {
    $exit_status = -8;
  }
  goto CLEANUP;
}

if( 0 == $exit_status ) {
  print_result($SUCCESS, "\n");
}

exit $exit_status;

####################################
sub print_usage() {
  my $prog = basename(__FILE__);
  print "-"x65 . "\n";
  print("Usage: $prog -np NUM_NODES -test TEST_NAME -path TEST_PATH\n");
  print "-"x65 . "\n";

  return 0;
}

####################################
sub parse_args() {
  my $argc = scalar(@ARGV);
  my $i;
  my $exit_value = 0;
  my $test_params;

  for( $i = 0; $i < $argc; ++$i) {

    # -np arg
    if( $ARGV[$i] =~ /-np/ ) {
      $i++;
      $global_np_arg = $ARGV[$i] + 0;
    }

    # Test to run
    elsif( $ARGV[$i] =~ /-test/ ) {
      $i++;
      $test_name = $ARGV[$i];
    }

    # Path to the test executables
    elsif( $ARGV[$i] =~ /-path/ ) {
      $i++;
      $test_path = $ARGV[$i];
    }

    # Print help
    elsif( $ARGV[$i] =~ /-h/ ) {
      $exit_value = -1;
    }

    # Verbosity Level
    elsif( $ARGV[$i] =~ /-v/ ) {
      $i++;
      $verbose = $ARGV[$i];
    }
  }

  if( $exit_value == 0 && !defined($test_name) ) {
    print("Error: Must provide a test name\n");
    $exit_value = -1;
  }
  elsif( $exit_value == 0 && $verbose > 0) {
    print "-"x20 . " General Parameters " . "-"x20 . "\n";
    print("\tTest Name   (-test   ): $test_name\n");
    print("\tNP          (-np     ): $global_np_arg\n");
    print "-"x60 . "\n";
  }

  return $exit_value;
}

#####################################
sub set_ftb_env() {
  my $hostname = `srun -N1 hostname`;
  chomp($hostname);
  my $addr = (gethostbyname($hostname))[4];
  my @oct = unpack(\'C4\', $addr);
  my $ip = join(".", @oct);

  print_verbose(1, "FTB Bootstrap Server: ". $hostname ." (". $ip .")\n");
  $ENV{\'FTB_BSTRAP_SERVER\'} = $ip;
  $ENV{\'FTB_BSTRAP_PORT\'} = 14455;
  $ENV{\'FTB_AGENT_PORT\'} = 10809;

  # Append the test path to the PATH env var
  $ENV{\'PATH\'} = $test_path . ":" . $ENV{\'PATH\'};

  print_verbose(1, "FTB_BSTRAP_SERVER: ". $ENV{\'FTB_BSTRAP_SERVER\'} ."\n");
  print_verbose(1, "FTB_BSTRAP_PORT: ". $ENV{\'FTB_BSTRAP_PORT\'} ."\n");
  print_verbose(1, "FTB_AGENT_PORT: ". $ENV{\'FTB_AGENT_PORT\'} ."\n");
  print_verbose(1, "PATH: ". $ENV{\'PATH\'} ."\n");

  return 0;
}

####################################
sub start_ftb_bstrap_server() {
  my $cmd;
  my $exit_status;

  #
  # Generate the FTB config file
  #
  set_ftb_env();

  $cmd = "mpirun -np 1 -bynode nohup $ftb_bstrap_server $drop_stdout &";
  print_verbose(1, "FTB Bootstrap Server Run Command: ". $cmd . "\n");

  #
  # Fork off a child process
  #
  $ftb_bstrap_pid = fork();
  if( !defined($ftb_bstrap_pid) ) {
    print_result($ERROR, "Failed to fork child.");
    $exit_status = -1;
    goto CLEANUP;
  }
  elsif(0 == $ftb_bstrap_pid ) { # Child
    exec($cmd);
    exit(-1);
  }
  else { # Parent
    print_verbose(1, "Parent Watching child PID ($ftb_bstrap_pid)\n");
  }

  print_verbose(1, "Server is returning.\n");

CLEANUP:
  return $exit_status;
}

####################################
sub start_ftb_agents() {
  my $cmd;
  my $exit_status;

  $cmd = "mpirun -np $global_np_arg -bynode nohup $ftb_agent $drop_stdout &";
  print_verbose(1, "FTB Agent Run Command: ". $cmd . "\n");

  #
  # Fork off a child process
  #
  $ftb_agent_pid = fork();
  if( !defined($ftb_agent_pid) ) {
    print_result($ERROR, "Failed to fork child.");
    $exit_status = -1;
    goto CLEANUP;
  }
  elsif(0 == $ftb_agent_pid ) { # Child
    exec($cmd);
    exit(-1);
  }
  else { # Parent
    print_verbose(1, "Parent Watching child PID ($ftb_agent_pid)\n");
  }

CLEANUP:
  return $exit_status;
}

#####################################
sub start_test() {
  my $cmd;
  my $exit_status = 0;

  $cmd = ("mpirun -bynode -np ".$global_np_arg." ".$test_name);
  print_verbose(1, "Test Run Command: ". $cmd . "\n");

  #
  # Fork off a child process
  #
  $test_child_pid = fork();
  if( !defined($test_child_pid) ) {
    print_result($ERROR, "Failed to fork child.");
    $exit_status = -1;
    goto CLEANUP;
  }
  elsif(0 == $test_child_pid ) { # Child
    exec($cmd);
    exit(-1);
  }
  else { # Parent
    print_verbose(1, "Parent Watching child PID ($test_child_pid)\n");
  }

 CLEANUP:
  return $exit_status;
}

#####################################
sub find_test_pid() {
  my @test_names = ($test_name);
  my $i;
  my $pid;
  my $cmd;

  my @values;

  foreach $i (@test_names) {
    $cmd = "ps eux | grep $i | awk \\\'{ print \$1 }\\\'";
    @values = `$cmd`;
    chomp(@values);

    # Command does not exits
    if(0 >= scalar(@values)) {
      ;
    }
    # More than one tests :(
    elsif( 1 != scalar(@values) ) {
      print "Error: More than one test [$test_name] for $USER\n";
      return -1;
    }
    # Only one value
    else {
      $pid = $values[0];
      last;
    }
  }

  if(!defined($pid) ) {
    return -1;
  }
  else {
    $test_child_pid = $pid;
  }

  return 0;
}

#####################################
sub post_cleanup() {
  my $cmd;
  my $exit_status = 0;

  # Wait for the test child to complete
  if( 0 < $test_child_pid ) {
    killall_procs($test_child_pid);

    $rtn = wait_child($test_child_pid, $timeout_total);
    $test_child_pid = 0;
    if( $rtn != 0 ) {
      print_result($ERROR, "Test Run Child Finished with non-zero exit status [$rtn]\n");
      $exit_status = 1;
    }
    else {
      print_verbose(2, "Test Run Child Finished (".$rtn.")\n");
    }
  }

  # Wait for the ftb agents to complete
  if( 0 < $ftb_agent_pid ) {
    killall_procs($ftb_agent_pid);

    $rtn = wait_child($ftb_agent_pid, $timeout_total);
    $ftb_agent_pid = 0;
    if( $rtn != 0 ) {
      print_result($ERROR, "FTB agents Finished with non-zero exit status [$rtn]\n");
      $exit_status = 2;
    }
    else {
      print_verbose(2, "FTB agents Finished (".$?.")\n");
    }
  }

  # Wait for the ftb bootstrap server to complete
  if( 0 < $ftb_bstrap_pid ) {
    killall_procs($ftb_bstrap_pid);

    $rtn = wait_child($ftb_bstrap_pid, $timeout_total);
    $ftb_bstrap_pid = 0;
    if( $rtn != 0 ) {
      print_result($ERROR, "FTB Bootstrap Server Finished with non-zero exit status [$rtn]\n");
      $exit_status = 3;
    }
    else {
      print_verbose(2, "FTB Bootstrap Server Finished (".$?.")\n");
    }
  }

  #
  # Kill any remaining procs
  #
  killall_procs($launcher);

  return $exit_status;
}

#####################################
sub print_banner() {
  my $str = shift(@_);

  print_verbose(1, "\n");
  print_verbose(1, "-"x10 . $str . "-"x10 . "\n");

  return 0;
}

sub print_verbose($$) {
  my $level = shift(@_);
  my $str = shift(@_);

  if( $verbose >= $level ) {
    print_result($INFO, $str);
  }

  return 0;
}

sub print_result($$) {
  my $error = shift(@_);
  my $str = shift(@_);

  if( $ERROR == $error ) {
    print("Final Result: ERROR) ");
  }
  elsif( $SUCCESS == $error ) {
    print("Final Result: SUCCESS) ");
  }
  elsif( $TIMED == $error ) {
    print("Final Result: TIMED OUT) ");
  }
  else {
    print("INFO) ");
  }

  print($str);

  return 0;
}

sub wait_child() {
  my $child_pid = shift(@_);
  my $timeout = shift(@_);
  my $cur_t = 0;
  my $rtn;
  my $exit_value = 0;

  $cur_t = 0;
  for($cur_t = 0; $cur_t <= $timeout || $timeout <= 0; ++$cur_t) {
    $rtn = waitpid($child_pid, WNOHANG);

    if( $rtn > 0 ) {
      $exit_value = $?;
      print_verbose(2, "Process Exited with [$exit_value]\n");
      last;
    }
    else {
      sleep(1);
      ++$cur_t;
    }
  }

  if($cur_t >= $timeout && $timeout > 0) {
    print_result($TIMED, "Process $child_pid Timed out! [waited $cur_t / $timeout]\n");
    #
    # Kill the process
    kill_procs($child_pid);

    #
    # Get the exit status
    $rtn = waitpid($child_pid, 0);
    $exit_value = $?;
  }

  return $exit_value;
}

sub kill_procs() {
  my @pids = @_;
  my $pid;
  my $cmd;

  $cmd = "";
  foreach $pid (@pids) {
    $cmd .= " " . $pid;
  }

  system("kill -TERM $cmd $drop_stdout");
  sleep(2);
  system("kill -KILL $cmd $drop_stdout");

  return 0;
}

sub killall_procs() {
  my @pids = @_;
  my $pid;
  my $cmd;

  $cmd = "";
  foreach $pid (@pids) {
    $cmd .= " " . $pid;
  }

  print_verbose(3, "Killing Procs: [$cmd]\n");
  system("srun \"killall -TERM $cmd \" $drop_stdout");
  sleep(2);
  system("srun \"killall -KILL $cmd \" $drop_stdout");

  return 0;
}

sub start_timer() {
  my $ref = shift(@_);
  $timer_start_val{$ref} = time();
  return 0;
}

sub end_timer() {
  my $ref = shift(@_);
  $timer_end_val{$ref} = time();
  return 0;
}

sub display_timer() {
  my $ref = shift(@_);
  my $sec;
  my $min;
  my $hr;
  my $day;
  my $str;

  $sec = ( ($timer_end_val{$ref}) - ($timer_start_val{$ref}));
  $min = $sec / 60.0;
  $hr  = $min / 60.0;
  $day = $hr  / 24.0;

  #$str = sprintf("(%6.2f min : %6.2f hr : %6.2f days : %10.1f sec)",
  #               $min, $hr, $day, $sec);

  $str = sprintf("%10.1f sec", $sec);

  return $str;
}
#####################################
';

    close(FILE);
    umask($u);
    return 0;
}


1;

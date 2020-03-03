package GearmanProxy::Log;

=head1 NAME

GearmanProxy::Log - logging utils

=head1 DESCRIPTION

Log Utilities

=cut

use warnings;
use strict;
use threads;
use Data::Dumper qw/Dumper/;
use Time::HiRes qw/gettimeofday/;

use base 'Exporter';
our @EXPORT_OK = qw(fatal error info debug trace);

our $loglevel = 1;
our $logfile;
our $newline = 1;

##############################################

=head2 loglevel

    set new loglevel or retrieve current one

=cut
sub loglevel {
    my($newlvl) = @_;
    $loglevel = $newlvl if defined $newlvl;
    return($loglevel);
}

##############################################

=head2 logfile

    set new logfile or retrieve current one

=cut
sub logfile {
    my($newfile) = @_;
    $logfile = $newfile if defined $newfile;
    return($logfile);
}

##############################################

=head2 fatal

    log something and exit

    printed when loglevel is >= 0

=cut
sub fatal {
    debug($_[0],'ERROR');
    exit(3);
}

##############################################

=head2 error

    log something with error loglevel

    printed when loglevel is >= 0

=cut
sub error {
    return debug($_[0],'ERROR');
}

##############################################

=head2 info

    log something with info loglevel

    printed when loglevel is >= 1

=cut
sub info {
    return debug($_[0],'INFO');
}

##############################################

=head2 trace

    log something with trace loglevel

    printed when loglevel is >= 3

=cut
sub trace {
    return debug($_[0],'TRACE');
}

##############################################

=head2 debug

    log something with debug loglevel

    printed when loglevel is >= 2

=cut
sub debug {
    my($txt, $lvl) = @_;
    return unless defined $txt;
    $lvl = 'DEBUG' unless defined $lvl;
    return if($loglevel < 3 and uc($lvl) eq 'TRACE');
    return if($loglevel < 2 and uc($lvl) eq 'DEBUG');
    return if($loglevel < 1 and uc($lvl) eq 'INFO');
    if(ref $txt) {
        return debug(Dumper($txt), $lvl);
    }

    my($fh, $close) = _get_fh();
    chomp($txt);
    my @txt = split(/\n/mx, $txt);
    my($seconds, $microseconds) = gettimeofday;
    for my $t (@txt)  {
        my $pad = ' ';
        if($t =~ m/^\[/mx) { $pad = ''; }
        printf($fh "[%s.%s][%s][thread-%s]%s%s%s",
                    POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($seconds)),
                    substr(sprintf("%06s", $microseconds), 0, 3), # zero pad microseconds to 6 digits and take the first 3 digits for milliseconds
                    $lvl,
                    threads->tid(),
                    $pad,
                    $t,
                    $newline ? "\n" : "",
        );
    }
    close($fh) if $close;

    return;
}

##############################################
sub _get_fh {
    my($fh, $close);
    if(!$logfile || lc($logfile) eq 'stdout' || $logfile eq '-') {
        $fh = *STDOUT;
    } elsif(lc($logfile) eq 'stderr') {
        $fh = *STDERR;
    } else {
        open($fh, ">>", $logfile) or die "open $logfile failed: ".$!;
        $close = 1;
    }
    return($fh, $close);
}

##############################################
sub TIEHANDLE {
    my($class, $fh) = @_;
    my $self = {
        fh => $fh,
    };
    bless $self, $class;
    return($self);
}

##############################################
sub BINMODE {
    my($self, $mode) = @_;
    return binmode $self->{'fh'}, $mode;
}

##############################################
sub PRINT {
    my($self, @data) = @_;

    my $nl = 1;
    if(join("", @data) !~ m/\n$/mx) {
        $nl = 0;
    }

    # if previous output did not have a newline, simply append text
    if(!$newline) {
        my($fh, $close) = _get_fh();
        print $fh @data;
        close($fh) if $close;
    } else {
        $newline = $nl;
        info(join("", @data));
    }

    $newline = $nl;

    return;
}

##############################################

1;

#!/usr/bin/perl

# SET THIS TO THE PATH TO YOUR SPOOL DIR!
my $spool   = '/var/spool/exim';
# SET THIS TO THE DEFAULT HEADER CHARACTER SET!
my $charset = 'ISO-8859-1';

# use 'exipick --help' to view documentation for this program.
# Documentation also viewable online at
#       http://www.exim.org/eximwiki/ToolExipickManPage

use strict;
use Getopt::Long;

my($p_name)   = $0 =~ m|/?([^/]+)$|;
my $p_version = "20061117.2";
my $p_usage   = "Usage: $p_name [--help|--version] (see --help for details)";
my $p_cp      = <<EOM;
        Copyright (c) 2003-2006 John Jetmore <jj33\@pobox.com>

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.
EOM
ext_usage(); # before we do anything else, check for --help

$| = 1; # unbuffer STDOUT

Getopt::Long::Configure("bundling_override");
GetOptions(
  'spool=s'     => \$G::spool,      # exim spool dir
  'bp'          => \$G::mailq_bp,   # List the queue (noop - default)
  'bpa'         => \$G::mailq_bpa,  # ... with generated address as well
  'bpc'         => \$G::mailq_bpc,  # ... but just show a count of messages
  'bpr'         => \$G::mailq_bpr,  # ... do not sort
  'bpra'        => \$G::mailq_bpra, # ... with generated addresses, unsorted
  'bpru'        => \$G::mailq_bpru, # ... only undelivered addresses, unsorted
  'bpu'         => \$G::mailq_bpu,  # ... only undelivered addresses
  'and'         => \$G::and,        # 'and' the criteria (default)
  'or'          => \$G::or,         # 'or' the criteria
  'f=s'         => \$G::qgrep_f,    # from regexp
  'r=s'         => \$G::qgrep_r,    # recipient regexp
  's=s'         => \$G::qgrep_s,    # match against size field
  'y=s'         => \$G::qgrep_y,    # message younger than (secs)
  'o=s'         => \$G::qgrep_o,    # message older than (secs)
  'z'           => \$G::qgrep_z,    # frozen only
  'x'           => \$G::qgrep_x,    # non-frozen only
  'c'           => \$G::qgrep_c,    # display match count
  'l'           => \$G::qgrep_l,    # long format (default)
  'i'           => \$G::qgrep_i,    # message ids only
  'b'           => \$G::qgrep_b,    # brief format
  'size'        => \$G::size_only,  # sum the size of the matching msgs
  'not'         => \$G::negate,     # flip every test
  'R|reverse'   => \$G::reverse,    # reverse output (-R is qgrep option)
  'sort=s'      => \@G::sort,       # allow you to choose variables to sort by
  'freeze=s'    => \$G::freeze,     # freeze data in this file
  'thaw=s'      => \$G::thaw,       # thaw data from this file
  'unsorted'    => \$G::unsorted,   # unsorted, regardless of output format
  'random'      => \$G::random,     # (poorly) randomize evaluation order
  'flatq'       => \$G::flatq,      # brief format
  'caseful'     => \$G::caseful,    # in '=' criteria, respect case
  'caseless'    => \$G::caseless,   #   ...ignore case (default)
  'charset=s'   => \$charset,       # charset for $bh and $h variables
  'show-vars=s' => \$G::show_vars,  # display the contents of these vars
  'just-vars'   => \$G::just_vars,  # only display vars, no other info
  'show-rules'  => \$G::show_rules, # display compiled match rules
  'show-tests'  => \$G::show_tests  # display tests as applied to each message
) || exit(1);

# if both freeze and thaw specified, only thaw as it is less desctructive
$G::freeze = undef               if ($G::freeze && $G::thaw);
freeze_start()                   if ($G::freeze);
thaw_start()                     if ($G::thaw);

# massage sort options (make '$var,Var:' be 'var','var')
for (my $i = scalar(@G::sort)-1; $i >= 0; $i--) {
  $G::sort[$i] = lc($G::sort[$i]);
  $G::sort[$i] =~ s/[\$:\s]//g;
  if ((my @vars = split(/,/, $G::sort[$i])) > 1) {
    $G::sort[$i] = $vars[0]; shift(@vars); # replace current slot w/ first var
    splice(@G::sort, $i+1, 0, @vars);      # add other vars after current pos
  }
}
push(@G::sort, "message_exim_id") if (@G::sort);
die "empty value provided to --sort not allowed, exiting\n"
    if (grep /^\s*$/, @G::sort);

# massage the qgrep options into standard criteria
push(@ARGV, "\$sender_address     =~ /$G::qgrep_f/") if ($G::qgrep_f);
push(@ARGV, "\$recipients         =~ /$G::qgrep_r/") if ($G::qgrep_r);
push(@ARGV, "\$shown_message_size eq $G::qgrep_s")   if ($G::qgrep_s);
push(@ARGV, "\$message_age        <  $G::qgrep_y")   if ($G::qgrep_y);
push(@ARGV, "\$message_age        >  $G::qgrep_o")   if ($G::qgrep_o);
push(@ARGV, "\$deliver_freeze")                      if ($G::qgrep_z);
push(@ARGV, "!\$deliver_freeze")                     if ($G::qgrep_x);

$G::mailq_bp        = $G::mailq_bp;        # shut up -w
$G::and             = $G::and;             # shut up -w
$G::msg_ids         = {};                  # short circuit when crit is only MID
$G::caseless        = $G::caseful ? 0 : 1; # nocase by default, case if both
@G::recipients_crit = ();                  # holds per-recip criteria
$spool              = $G::spool if ($G::spool);
my $count_only      = 1 if ($G::mailq_bpc  || $G::qgrep_c);
my $unsorted        = 1 if ($G::mailq_bpr  || $G::mailq_bpra ||
                            $G::mailq_bpru || $G::unsorted);
my $msg             = $G::thaw ? thaw_message_list()
                               : get_all_msgs($spool, $unsorted,
                                              $G::reverse, $G::random);
die "Problem accessing thaw file\n" if ($G::thaw && !$msg);
my $crit            = process_criteria(\@ARGV);
my $e               = Exim::SpoolFile->new();
my $tcount          = 0 if ($count_only);  # holds count of all messages
my $mcount          = 0 if ($count_only);  # holds count of matching messages
my $total_size      = 0 if ($G::size_only);
$e->set_undelivered_only(1)      if ($G::mailq_bpru || $G::mailq_bpu);
$e->set_show_generated(1)        if ($G::mailq_bpra || $G::mailq_bpa);
$e->output_long()                if ($G::qgrep_l);
$e->output_idonly()              if ($G::qgrep_i);
$e->output_brief()               if ($G::qgrep_b);
$e->output_flatq()               if ($G::flatq);
$e->output_vars_only()           if ($G::just_vars && $G::show_vars);
$e->set_show_vars($G::show_vars) if ($G::show_vars);
$e->set_spool($spool);

MSG:
foreach my $m (@$msg) {
  next if (scalar(keys(%$G::msg_ids)) && !$G::or
                                      && !$G::msg_ids->{$m->{message}});
  if ($G::thaw) {
    my $data = thaw_data();
    if (!$e->restore_state($data)) {
      warn "Couldn't thaw $data->{_message}: ".$e->error()."\n";
      next MSG;
    }
  } else {
    if (!$e->parse_message($m->{message}, $m->{path})) {
      warn "Couldn't parse $m->{message}: ".$e->error()."\n";
      next MSG;
    }
  }
  $tcount++;
  my $match = 0;
  my @local_crit = ();
  foreach my $c (@G::recipients_crit) {              # handle each_recip* vars
    foreach my $addr (split(/, /, $e->get_var($c->{var}))) {
      my %t = ( 'cmp' => $c->{cmp}, 'var' => $c->{var} );
      $t{cmp} =~ s/"?\$var"?/'$addr'/;
      push(@local_crit, \%t);
    }
  }
  if ($G::show_tests) { print $e->get_var('message_exim_id'), "\n"; }
  CRITERIA:
  foreach my $c (@$crit, @local_crit) {
    my $var = $e->get_var($c->{var});
    my $ret = eval($c->{cmp});
    if ($G::show_tests) {
      printf "  %25s =  '%s'\n  %25s => $ret\n",$c->{var},$var,$c->{cmp},$ret;
    }
    if ($@) {
      print STDERR "Error in eval '$c->{cmp}': $@\n";
      next MSG;
    } elsif ($ret) {
      $match = 1;
      if ($G::or) { last CRITERIA; }
      else        { next CRITERIA; }
    } else { # no match
      if ($G::or) { next CRITERIA; }
      else        { next MSG;      }
    }
  }

  # skip this message if any criteria were supplied and it didn't match
  next MSG if ((scalar(@$crit) || scalar(@local_crit)) && !$match);

  if ($count_only || $G::size_only) {
    $mcount++;
    $total_size += $e->get_var('message_size');
  } else {
    if (@G::sort) {
      # if we are defining criteria to sort on, save the message here.  If
      # we don't save here and do the sort later, we have a chicken/egg
      # problem
      push(@G::to_print, { vars => {}, output => "" });
      foreach my $var (@G::sort) {
        # save any values we want to sort on.  I don't like doing the internal
        # struct access here, but calling get_var a bunch can be _slow_ =(
        $G::sort_type{$var} ||= '<=>';
        $G::to_print[-1]{vars}{$var} = $e->{_vars}{$var};
        $G::sort_type{$var} = 'cmp' if ($G::to_print[-1]{vars}{$var} =~ /\D/);
      }
      $G::to_print[-1]{output} = $e->format_message();
    } else {
      print $e->format_message();
    }
  }

  if ($G::freeze) {
    freeze_data($e->get_state());
    push(@G::frozen_msgs, $m);
  }
}

if (@G::to_print) {
  msg_sort(\@G::to_print, \@G::sort, $G::reverse);
  foreach my $msg (@G::to_print) {
    print $msg->{output};
  }
}

if ($G::qgrep_c) {
  print "$mcount matches out of $tcount messages" .
        ($G::size_only ? " ($total_size)" : "") . "\n";
} elsif ($G::mailq_bpc) {
  print "$mcount" .  ($G::size_only ? " ($total_size)" : "") . "\n";
} elsif ($G::size_only) {
  print "$total_size\n";
}

if ($G::freeze) {
  freeze_message_list(\@G::frozen_msgs);
  freeze_end();
} elsif ($G::thaw) {
  thaw_end();
}

exit;

# sender_address_domain,shown_message_size
sub msg_sort {
  my $msgs    = shift;
  my $vars    = shift;
  my $reverse = shift;

  my @pieces = ();
  foreach my $v (@G::sort) {
    push(@pieces, "\$a->{vars}{\"$v\"} $G::sort_type{$v} \$b->{vars}{\"$v\"}");
  }
  my $sort_str = join(" || ", @pieces);

  @$msgs = sort { eval $sort_str } (@$msgs);
  @$msgs = reverse(@$msgs) if ($reverse);
}

sub try_load {
  my $mod = shift;

  eval("use $mod");
  return $@ ? 0 : 1;
}

# FREEZE FILE FORMAT:
# message_data_bytes
# message_data
# <...>
# EOM
# message_list
# message_list_bytes <- 10 bytes, zero-packed, plus \n

sub freeze_start {
  eval("use Storable");
  die "Storable module not found: $@\n" if ($@);
  open(O, ">$G::freeze") || die "Can't open freeze file $G::freeze: $!\n";
  $G::freeze_handle = \*O;
}

sub freeze_end {
  close($G::freeze_handle);
}

sub thaw_start {
  eval("use Storable");
  die "Storable module not found: $@\n" if ($@);
  open(I, "<$G::thaw") || die "Can't open freeze file $G::thaw: $!\n";
  $G::freeze_handle = \*I;
}

sub thaw_end {
  close($G::freeze_handle);
}

sub freeze_data {
  my $h = Storable::freeze($_[0]);
  print $G::freeze_handle length($h)+1, "\n$h\n";
}

sub freeze_message_list {
  my $h = Storable::freeze($_[0]);
  my $l = length($h) + 1;
  printf $G::freeze_handle "EOM\n$l\n$h\n%010d\n", $l+11+length($l)+1;
}

sub thaw_message_list {
  my $orig_pos = tell($G::freeze_handle);
  seek($G::freeze_handle, -11, 2);
  chomp(my $bytes = <$G::freeze_handle>);
  seek($G::freeze_handle, $bytes * -1, 2);
  my $obj = thaw_data();
  seek($G::freeze_handle, 0, $orig_pos);
  return($obj);
}

sub thaw_data {
  my $obj;
  chomp(my $bytes = <$G::freeze_handle>);
  return(undef) if (!$bytes || $bytes eq 'EOM');
  my $read = read(I, $obj, $bytes);
  die "Format error in thaw file (expected $bytes bytes, got $read)\n"
      if ($bytes != $read);
  chomp($obj);
  return(Storable::thaw($obj));
}

sub process_criteria {
  my $a = shift;
  my @c = ();
  my $e = 0;

  foreach (@$a) {
    foreach my $t ('@') { s/$t/\\$t/g; }
    if (/^(.*?)\s+(<=|>=|==|!=|<|>)\s+(.*)$/) {
      #print STDERR "found as integer\n";
      my $v = $1; my $o = $2; my $n = $3;
      if    ($n =~ /^(-?[\d\.]+)M$/)  { $n = $1 * 1024 * 1024; }
      elsif ($n =~ /^(-?[\d\.]+)K$/)  { $n = $1 * 1024; }
      elsif ($n =~ /^(-?[\d\.]+)B?$/) { $n = $1; }
      elsif ($n =~ /^(-?[\d\.]+)d$/)  { $n = $1 * 60 * 60 * 24; }
      elsif ($n =~ /^(-?[\d\.]+)h$/)  { $n = $1 * 60 * 60; }
      elsif ($n =~ /^(-?[\d\.]+)m$/)  { $n = $1 * 60; }
      elsif ($n =~ /^(-?[\d\.]+)s?$/) { $n = $1; }
      else {
        print STDERR "Expression $_ did not parse: numeric comparison with ",
                     "non-number\n";
        $e = 1;
        next;
      }
      push(@c, { var => lc($v), cmp => "(\$var $o $n)" });
    } elsif (/^(.*?)\s+(=~|!~)\s+(.*)$/) {
      #print STDERR "found as string regexp\n";
      push(@c, { var => lc($1), cmp => "(\"\$var\" $2 $3)" });
    } elsif (/^(.*?)\s+=\s+(.*)$/) {
      #print STDERR "found as bare string regexp\n";
      my $case = $G::caseful ? '' : 'i';
      push(@c, { var => lc($1), cmp => "(\"\$var\" =~ /$2/$case)" });
      # quote special characters in perl text string
      #foreach my $t ('@') { $c[-1]{cmp} =~ s/$t/\\$t/g; }
    } elsif (/^(.*?)\s+(eq|ne)\s+(.*)$/) {
      #print STDERR "found as string cmp\n";
      my $var = lc($1); my $op = $2; my $val = $3;
      $val =~ s|^(['"])(.*)\1$|$2|;
      push(@c, { var => $var, cmp => "(\"\$var\" $op \"$val\")" });
      if (($var eq 'message_id' || $var eq 'message_exim_id') && $op eq "eq") {
        #print STDERR "short circuit @c[-1]->{cmp} $val\n";
        $G::msg_ids->{$val} = 1;
      }
      #foreach my $t ('@') { $c[-1]{cmp} =~ s/$t/\\$t/g; }
    } elsif (/^(\S+)$/) {
      #print STDERR "found as boolean\n";
      push(@c, { var => lc($1), cmp => "(\$var)" });
    } else {
      print STDERR "Expression $_ did not parse\n";
      $e = 1;
      next;
    }
    # assign the results of the cmp test here (handle "!" negation)
    # also handle global --not negation
    if ($c[-1]{var} =~ s|^!||) {
      $c[-1]{cmp} .= $G::negate ? " ? 1 : 0" : " ? 0 : 1";
    } else {
      $c[-1]{cmp} .= $G::negate ? " ? 0 : 1" : " ? 1 : 0";
    }
    # support the each_* psuedo variables.  Steal the criteria off of the
    # queue for special processing later
    if ($c[-1]{var} =~ /^each_(recipients(_(un)?del)?)$/) {
      my $var = $1;
      push(@G::recipients_crit,pop(@c));
      $G::recipients_crit[-1]{var} = $var; # remove each_ from the variable
    }
  }

  exit(1) if ($e);

  if ($G::show_rules) { foreach (@c) { print "$_->{var}\t$_->{cmp}\n"; } }

  return(\@c);
}

sub get_all_msgs {
  my $d = shift() . '/input';
  my $u = shift; # don't sort
  my $r = shift; # right before returning, reverse order
  my $o = shift; # if true, randomize list order before returning
  my @m = ();

  opendir(D, "$d") || die "Couldn't opendir $d: $!\n";
  foreach my $e (grep !/^\./, readdir(D)) {
    if ($e =~ /^[a-zA-Z0-9]$/) {
      opendir(DD, "$d/$e") || next;
      foreach my $f (grep !/^\./, readdir(DD)) {
        push(@m, { message => $1, path => "$d/$e" }) if ($f =~ /^(.{16})-H$/);
      }
      closedir(DD);
    } elsif ($e =~ /^(.{16})-H$/) {
      push(@m, { message => $1, path => $d });
    }
  }
  closedir(D);

  if ($o) {
    my $c = scalar(@m);
    # loop twice to pretend we're doing a good job of mixing things up
    for (my $i = 0; $i < 2 * $c; $i++) {
      my $rand = int(rand($c));
      ($m[$i % $c],$m[$rand]) = ($m[$rand],$m[$i % $c]);
    }
  } elsif (!$u) {
    @m = sort { $a->{message} cmp $b->{message} } @m;
  }
  @m = reverse(@m) if ($r);

  return(\@m);
}

BEGIN {

package Exim::SpoolFile;

# versions 4.61 and higher will not need these variables anymore, but they
# are left for handling legacy installs
$Exim::SpoolFile::ACL_C_MAX_LEGACY = 10;
#$Exim::SpoolFile::ACL_M_MAX _LEGACY= 10;

sub new {
  my $class = shift;
  my $self  = {};
  bless($self, $class);

  $self->{_spool_dir}        = '';
  $self->{_undelivered_only} = 0;
  $self->{_show_generated}   = 0;
  $self->{_output_long}      = 1;
  $self->{_output_idonly}    = 0;
  $self->{_output_brief}     = 0;
  $self->{_output_flatq}     = 0;
  $self->{_output_vars_only} = 0;
  $self->{_show_vars}        = [];

  $self->_reset();
  return($self);
}

sub output_long {
  my $self = shift;

  $self->{_output_long}      = 1;
  $self->{_output_idonly}    = 0;
  $self->{_output_brief}     = 0;
  $self->{_output_flatq}     = 0;
  $self->{_output_vars_only} = 0;
}

sub output_idonly {
  my $self = shift;

  $self->{_output_long}      = 0;
  $self->{_output_idonly}    = 1;
  $self->{_output_brief}     = 0;
  $self->{_output_flatq}     = 0;
  $self->{_output_vars_only} = 0;
}

sub output_brief {
  my $self = shift;

  $self->{_output_long}      = 0;
  $self->{_output_idonly}    = 0;
  $self->{_output_brief}     = 1;
  $self->{_output_flatq}     = 0;
  $self->{_output_vars_only} = 0;
}

sub output_flatq {
  my $self = shift;

  $self->{_output_long}      = 0;
  $self->{_output_idonly}    = 0;
  $self->{_output_brief}     = 0;
  $self->{_output_flatq}     = 1;
  $self->{_output_vars_only} = 0;
}

sub output_vars_only {
  my $self = shift;

  $self->{_output_long}      = 0;
  $self->{_output_idonly}    = 0;
  $self->{_output_brief}     = 0;
  $self->{_output_flatq}     = 0;
  $self->{_output_vars_only} = 1;
}

sub set_show_vars {
  my $self = shift;
  my $s    = shift;

  foreach my $v (split(/\s*,\s*/, $s)) {
    push(@{$self->{_show_vars}}, $v);
  }
}

sub set_show_generated {
  my $self = shift;
  $self->{_show_generated} = shift;
}

sub set_undelivered_only {
  my $self = shift;
  $self->{_undelivered_only} = shift;
}

sub error {
  my $self = shift;
  return $self->{_error};
}

sub _error {
  my $self = shift;
  $self->{_error} = shift;
  return(undef);
}

sub _reset {
  my $self = shift;

  $self->{_error}       = '';
  $self->{_delivered}   = 0;
  $self->{_message}     = '';
  $self->{_path}        = '';
  $self->{_vars}        = {};
  $self->{_vars_raw}    = {};

  $self->{_numrecips}   = 0;
  $self->{_udel_tree}   = {};
  $self->{_del_tree}    = {};
  $self->{_recips}      = {};

  return($self);
}

sub parse_message {
  my $self = shift;

  $self->_reset();
  $self->{_message} = shift || return(0);
  $self->{_path}    = shift; # optional path to message
  return(0) if (!$self->{_spool_dir});
  if (!$self->{_path} && !$self->_find_path()) {
    # assume the message was delivered from under us and ignore
    $self->{_delivered} = 1;
    return(1);
  }
  $self->_parse_header() || return(0);

  return(1);
}

# take the output of get_state() and set up a message internally like
# parse_message (except from a saved data struct, not by parsing the
# files on disk).
sub restore_state {
  my $self = shift;
  my $h    = shift;

  return(1) if ($h->{_delivered});
  $self->_reset();
  $self->{_message} = $h->{_message} || return(0);
  return(0) if (!$self->{_spool_dir});

  $self->{_path}      = $h->{_path};
  $self->{_vars}      = $h->{_vars};
  $self->{_numrecips} = $h->{_numrecips};
  $self->{_udel_tree} = $h->{_udel_tree};
  $self->{_del_tree}  = $h->{_del_tree};
  $self->{_recips}    = $h->{_recips};

  $self->{_vars}{message_age} = time() - $self->{_vars}{received_time};
  return(1);
}

# This returns the state data for a specific message in a format that can
# be later frozen back in to regain state
#
# after calling this function, this specific state is not expect to be
# reused.  That's because we're returning direct references to specific
# internal structures.  We're also modifying the structure ourselves
# by deleting certain internal message variables.
sub get_state {
  my $self = shift;
  my $h    = {};    # this is the hash ref we'll be returning.

  $h->{_delivered} = $self->{_delivered};
  $h->{_message}   = $self->{_message};
  $h->{_path}      = $self->{_path};
  $h->{_vars}      = $self->{_vars};
  $h->{_numrecips} = $self->{_numrecips};
  $h->{_udel_tree} = $self->{_udel_tree};
  $h->{_del_tree}  = $self->{_del_tree};
  $h->{_recips}    = $self->{_recips};

  # delete some internal variables that we will rebuild later if needed
  delete($h->{_vars}{message_body});
  delete($h->{_vars}{message_age});

  return($h);
}

# keep this sub as a feature if we ever break this module out, but do away
# with its use in exipick (pass it in from caller instead)
sub _find_path {
  my $self = shift;

  return(0) if (!$self->{_message});
  return(0) if (!$self->{_spool_dir});

  # test split spool first on the theory that people concerned about
  # performance will have split spool set =).
  foreach my $f (substr($self->{_message}, 5, 1).'/', '') {
    if (-f "$self->{_spool_dir}/input/$f$self->{_message}-H") {
      $self->{_path} = $self->{_spool_dir} . "/input/$f";
      return(1);
    }
  }
  return(0);
}

sub set_spool {
  my $self = shift;
  $self->{_spool_dir} = shift;
}

sub get_matching_vars {
  my $self = shift;
  my $e    = shift;

  if ($e =~ /^\^/) {
    my @r = ();
    foreach my $v (keys %{$self->{_vars}}) { push(@r, $v) if ($v =~ /$e/); }
    return(@r);
  } else {
    return($e);
  }
}

# accepts a variable with or without leading '$' or trailing ':'
sub get_var {
  my $self = shift;
  my $var  = lc(shift); $var =~ s/^\$//; $var =~ s/:$//;

  if ($var eq 'message_body' && !defined($self->{_vars}{message_body})) {
    $self->_parse_body()
  } elsif ($var =~ s|^([rb]?h)(eader)?_|${1}eader_| &&
           exists($self->{_vars}{$var}) && !defined($self->{_vars}{$var}))
  {
    if ((my $type = $1) eq 'rh') {
      $self->{_vars}{$var} = join('', @{$self->{_vars_raw}{$var}{vals}});
    } else {
      # both bh_ and h_ build their strings from rh_.  Do common work here
      my $rh = $var; $rh =~ s|^b?|r|;
      my $comma = 1 if ($self->{_vars_raw}{$rh}{type} =~ /^[BCFRST]$/);
      foreach (@{$self->{_vars_raw}{$rh}{vals}}) {
        my $x = $_; # editing $_ here would change the original, which is bad
        $x =~ s|^\s+||;
        $x =~ s|\s+$||;
        if ($comma) { chomp($x); $self->{_vars}{$var} .= "$x,\n"; }
        else        { $self->{_vars}{$var} .= $x; }
      }
      $self->{_vars}{$var} =~ s|[\s\n]*$||;
      $self->{_vars}{$var} =~ s|,$|| if ($comma);
      # ok, that's the preprocessing, not do specific processing for h type
      if ($type eq 'bh') {
        $self->{_vars}{$var} = $self->_decode_2047($self->{_vars}{$var});
      } else {
        $self->{_vars}{$var} =
            $self->_decode_2047($self->{_vars}{$var}, $charset);
      }
    }
  }
  elsif ($var eq 'received_count' && !defined($self->{_vars}{received_count}))
  {
    $self->{_vars}{received_count} =
        scalar(@{$self->{_vars_raw}{rheader_received}{vals}});
  }
  elsif ($var eq 'message_headers' && !defined($self->{_vars}{message_headers}))
  {
    $self->{_vars}{$var} =
        $self->_decode_2047($self->{_vars}{message_headers_raw}, $charset);
    chomp($self->{_vars}{$var});
  }
  elsif ($var eq 'reply_address' && !defined($self->{_vars}{reply_address}))
  {
    $self->{_vars}{reply_address} = exists($self->{_vars}{"header_reply-to"})
        ? $self->get_var("header_reply-to") : $self->get_var("header_from");
  }

  #chomp($self->{_vars}{$var}); # I think this was only for headers, obsolete
  return $self->{_vars}{$var};
}

sub _decode_2047 {
  my $self = shift;
  my $s    = shift; # string to decode
  my $c    = shift; # target charset.  If empty, just decode, don't convert
  my $t    = '';    # the translated string
  my $e    = 0;     # set to true if we get an error in here anywhere

  return($s) if ($s !~ /=\?/); # don't even bother to look if there's no sign

  my @p = ();
  foreach my $mw (split(/(=\?[^\?]{3,}\?[BQ]\?[^\?]{1,74}\?=)/i, $s)) {
    next if ($mw eq '');
    if ($mw =~ /=\?([^\?]{3,})\?([BQ])\?([^\?]{1,74})\?=/i) {
      push(@p, { data => $3, encoding => uc($2), charset => uc($1),
                 is_mime => 1 });
      if ($p[-1]{encoding} eq 'Q') {
        my @ow = split('', $p[-1]{data});
        my @nw = ();
        for (my $i = 0; $i < @ow; $i++) {
          if ($ow[$i] eq '_') { push(@nw, ' '); }
          elsif ($ow[$i] eq '=') {
            if (scalar(@ow) - ($i+1) < 2) {  # ran out of characters
              $e = 1; last;
            } elsif ($ow[$i+1] !~ /[\dA-F]/i || $ow[$i+2] !~ /[\dA-F]/i) {
              $e = 1; last;
            } else {
              #push(@nw, chr('0x'.$ow[$i+1].$ow[$i+2]));
              push(@nw, pack("C", hex($ow[$i+1].$ow[$i+2])));
              $i += 2;
            }
          }
          elsif ($ow[$i] =~ /\s/) { # whitspace is illegal
            $e = 1;
            last;
          }
          else { push(@nw, $ow[$i]); }
        }
        $p[-1]{data} = join('', @nw);
      } elsif ($p[-1]{encoding} eq 'B') {
        my $x = $p[-1]{data};
        $x    =~ tr#A-Za-z0-9+/##cd;
        $x    =~ s|=+$||;
        $x    =~ tr#A-Za-z0-9+/# -_#;
        my $r = '';
        while ($x =~ s/(.{1,60})//s) {
          $r .= unpack("u", chr(32 + int(length($1)*3/4)) . $1);
        }
        $p[-1]{data} = $r;
      }
    } else {
      push(@p, { data => $mw, is_mime => 0,
                 is_ws => ($mw =~ m|^[\s\n]+|sm) ? 1 : 0 });
    }
  }

  for (my $i = 0; $i < @p; $i++) {
    # mark entities we want to skip (whitespace between consecutive mimewords)
    if ($p[$i]{is_mime} && $p[$i+1]{is_ws} && $p[$i+2]{is_mime}) {
      $p[$i+1]{skip} = 1;
    }

    # if word is a mimeword and we have access to Encode and charset was
    # specified, try to convert text
    # XXX _cannot_ get consistent conversion results in perl, can't get them
    # to return same conversions that exim performs.  Until I can figure this
    # out, don't attempt any conversions (header_ will return same value as
    # bheader_).
    #if ($c && $p[$i]{is_mime} && $self->_try_load('Encode')) {
    #  # XXX not sure how to catch errors here
    #  Encode::from_to($p[$i]{data}, $p[$i]{charset}, $c);
    #}

    # replace binary zeros w/ '?' in decoded text
    if ($p[$i]{is_mime}) { $p[$i]{data} =~ s|\x00|?|g; }
  }

  if ($e) {
    return($s);
  } else {
    return(join('', map { $_->{data} } grep { !$_->{skip} } @p));
  }
}

# This isn't a class func but I'm tired
sub _try_load {
  my $self = shift;
  my $mod  = shift;

  eval("use $mod");
  return $@ ? 0 : 1;
}

sub _parse_body {
  my $self = shift;
  my $f    = $self->{_path} . '/' . $self->{_message} . '-D';
  $self->{_vars}{message_body} = ""; # define var so we only come here once

  open(I, "<$f") || return($self->_error("Couldn't open $f: $!"));
  chomp($_ = <I>);
  return(0) if ($self->{_message}.'-D' ne $_);

  $self->{_vars}{message_body} = join('', <I>);
  close(I);
  $self->{_vars}{message_body} =~ s/\n/ /g;
  $self->{_vars}{message_body} =~ s/\000/ /g;
  return(1);
}

sub _parse_header {
  my $self = shift;
  my $f    = $self->{_path} . '/' . $self->{_message} . '-H';

  if (!open(I, "<$f")) {
    # assume message went away and silently ignore
    $self->{_delivered} = 1;
    return(1);
  }

  # There are a few numeric variables that should explicitly be set to
  # zero if they aren't found in the header.  Technically an empty value
  # works just as well, but might as well be pedantic
  $self->{_vars}{body_zerocount}           = 0;
  $self->{_vars}{host_lookup_deferred}     = 0;
  $self->{_vars}{host_lookup_failed}       = 0;
  $self->{_vars}{tls_certificate_verified} = 0;

  chomp($_ = <I>);
  return(0) if ($self->{_message}.'-H' ne $_);
  $self->{_vars}{message_id}       = $self->{_message};
  $self->{_vars}{message_exim_id}  = $self->{_message};

  # line 2
  chomp($_ = <I>);
  return(0) if (!/^(.+)\s(\-?\d+)\s(\-?\d+)$/);
  $self->{_vars}{originator_login} = $1;
  $self->{_vars}{originator_uid}   = $2;
  $self->{_vars}{originator_gid}   = $3;

  # line 3
  chomp($_ = <I>);
  return(0) if (!/^<(.*)>$/);
  $self->{_vars}{sender_address}   = $1;
  $self->{_vars}{sender_address_domain} = $1;
  $self->{_vars}{sender_address_local_part} = $1;
  $self->{_vars}{sender_address_domain} =~ s/^.*\@//;
  $self->{_vars}{sender_address_local_part} =~ s/^(.*)\@.*$/$1/;

  # line 4
  chomp($_ = <I>);
  return(0) if (!/^(\d+)\s(\d+)$/);
  $self->{_vars}{received_time}    = $1;
  $self->{_vars}{warning_count}    = $2;
  $self->{_vars}{message_age}      = time() - $self->{_vars}{received_time};

  while (<I>) {
    chomp();
    if (/^(-\S+)\s*(.*$)/) {
      my $tag = $1;
      my $arg = $2;
      if ($tag eq '-acl') {
        my $t;
        return(0) if ($arg !~ /^(\d+)\s(\d+)$/);
        if ($1 < $Exim::SpoolFile::ACL_C_MAX_LEGACY) {
          $t = "acl_c$1";
        } else {
          $t = "acl_m" . ($1 - $Exim::SpoolFile::ACL_C_MAX_LEGACY);
        }
        read(I, $self->{_vars}{$t}, $2+1) || return(0);
        chomp($self->{_vars}{$t});
      } elsif ($tag eq '-aclc') {
        #return(0) if ($arg !~ /^(\d+)\s(\d+)$/);
        return(0) if ($arg !~ /^(\S+)\s(\d+)$/);
        my $t = "acl_c$1";
        read(I, $self->{_vars}{$t}, $2+1) || return(0);
        chomp($self->{_vars}{$t});
      } elsif ($tag eq '-aclm') {
        #return(0) if ($arg !~ /^(\d+)\s(\d+)$/);
        return(0) if ($arg !~ /^(\S+)\s(\d+)$/);
        my $t = "acl_m$1";
        read(I, $self->{_vars}{$t}, $2+1) || return(0);
        chomp($self->{_vars}{$t});
      } elsif ($tag eq '-local') {
        $self->{_vars}{sender_local} = 1;
      } elsif ($tag eq '-localerror') {
        $self->{_vars}{local_error_message} = 1;
      } elsif ($tag eq '-local_scan') {
        $self->{_vars}{local_scan_data} = $arg;
      } elsif ($tag eq '-spam_score_int') {
        $self->{_vars}{spam_score_int} = $arg;
        $self->{_vars}{spam_score}     = $arg / 10;
      } elsif ($tag eq '-bmi_verdicts') {
        $self->{_vars}{bmi_verdicts} = $arg;
      } elsif ($tag eq '-host_lookup_deferred') {
        $self->{_vars}{host_lookup_deferred} = 1;
      } elsif ($tag eq '-host_lookup_failed') {
        $self->{_vars}{host_lookup_failed} = 1;
      } elsif ($tag eq '-body_linecount') {
        $self->{_vars}{body_linecount} = $arg;
      } elsif ($tag eq '-body_zerocount') {
        $self->{_vars}{body_zerocount} = $arg;
      } elsif ($tag eq '-frozen') {
        $self->{_vars}{deliver_freeze} = 1;
        $self->{_vars}{deliver_frozen_at} = $arg;
      } elsif ($tag eq '-allow_unqualified_recipient') {
        $self->{_vars}{allow_unqualified_recipient} = 1;
      } elsif ($tag eq '-allow_unqualified_sender') {
        $self->{_vars}{allow_unqualified_sender} = 1;
      } elsif ($tag eq '-deliver_firsttime') {
        $self->{_vars}{deliver_firsttime} = 1;
        $self->{_vars}{first_delivery} = 1;
      } elsif ($tag eq '-manual_thaw') {
        $self->{_vars}{deliver_manual_thaw} = 1;
        $self->{_vars}{manually_thawed} = 1;
      } elsif ($tag eq '-auth_id') {
        $self->{_vars}{authenticated_id} = $arg;
      } elsif ($tag eq '-auth_sender') {
        $self->{_vars}{authenticated_sender} = $arg;
      } elsif ($tag eq '-sender_set_untrusted') {
        $self->{_vars}{sender_set_untrusted} = 1;
      } elsif ($tag eq '-tls_certificate_verified') {
        $self->{_vars}{tls_certificate_verified} = 1;
      } elsif ($tag eq '-tls_cipher') {
        $self->{_vars}{tls_cipher} = $arg;
      } elsif ($tag eq '-tls_peerdn') {
        $self->{_vars}{tls_peerdn} = $arg;
      } elsif ($tag eq '-host_address') {
        $self->{_vars}{sender_host_port} = $self->_get_host_and_port(\$arg);
        $self->{_vars}{sender_host_address} = $arg;
      } elsif ($tag eq '-interface_address') {
        $self->{_vars}{received_port} =
            $self->{_vars}{interface_port} = $self->_get_host_and_port(\$arg);
        $self->{_vars}{received_ip_address} =
            $self->{_vars}{interface_address} = $arg;
      } elsif ($tag eq '-active_hostname') {
        $self->{_vars}{smtp_active_hostname} = $arg;
      } elsif ($tag eq '-host_auth') {
        $self->{_vars}{sender_host_authenticated} = $arg;
      } elsif ($tag eq '-host_name') {
        $self->{_vars}{sender_host_name} = $arg;
      } elsif ($tag eq '-helo_name') {
        $self->{_vars}{sender_helo_name} = $arg;
      } elsif ($tag eq '-ident') {
        $self->{_vars}{sender_ident} = $arg;
      } elsif ($tag eq '-received_protocol') {
        $self->{_vars}{received_protocol} = $arg;
      } elsif ($tag eq '-N') {
        $self->{_vars}{dont_deliver} = 1;
      } else {
        # unrecognized tag, save it for reference
        $self->{$tag} = $arg;
      }
    } else {
      last;
    }
  }

  # when we drop out of the while loop, we have the first line of the
  # delivered tree in $_
  do {
    if ($_ eq 'XX') {
      ; # noop
    } elsif ($_ =~ s/^[YN][YN]\s+//) {
      $self->{_del_tree}{$_} = 1;
    } else {
      return(0);
    }
    chomp($_ = <I>);
  } while ($_ !~ /^\d+$/);

  $self->{_numrecips} = $_;
  $self->{_vars}{recipients_count} = $self->{_numrecips};
  for (my $i = 0; $i < $self->{_numrecips}; $i++) {
    chomp($_ = <I>);
    return(0) if (/^$/);
    my $addr = '';
    if (/^(.*)\s\d+,(\d+),\d+$/) {
      #print STDERR "exim3 type (untested): $_\n";
      $self->{_recips}{$1} = { pno => $2 };
      $addr = $1;
    } elsif (/^(.*)\s(\d+)$/) {
      #print STDERR "exim4 original type (untested): $_\n";
      $self->{_recips}{$1} = { pno => $2 };
      $addr = $1;
    } elsif (/^(.*)\s(.*)\s(\d+),(\d+)#1$/) {
      #print STDERR "exim4 new type #1 (untested): $_\n";
      return($self->_error("incorrect format: $_")) if (length($2) != $3);
      $self->{_recips}{$1} = { pno => $4, errors_to => $2 };
      $addr = $1;
    } elsif (/^.*#(\d+)$/) {
      #print STDERR "exim4 #$1 style (unimplemented): $_\n";
      $self->_error("exim4 #$1 style (unimplemented): $_");
    } else {
      #print STDERR "default type: $_\n";
      $self->{_recips}{$_} = {};
      $addr = $_;
    }
    $self->{_udel_tree}{$addr} = 1 if (!$self->{_del_tree}{$addr});
  }
  $self->{_vars}{recipients}         = join(', ', keys(%{$self->{_recips}}));
  $self->{_vars}{recipients_del}     = join(', ', keys(%{$self->{_del_tree}}));
  $self->{_vars}{recipients_undel}   = join(', ', keys(%{$self->{_udel_tree}}));
  $self->{_vars}{recipients_undel_count} = scalar(keys(%{$self->{_udel_tree}}));
  $self->{_vars}{recipients_del_count}   = 0;
  foreach my $r (keys %{$self->{_del_tree}}) {
    next if (!$self->{_recips}{$r});
    $self->{_vars}{recipients_del_count}++;
  }

  # blank line
  $_ = <I>;
  return(0) if (!/^$/);

  # start reading headers
  while (read(I, $_, 3) == 3) {
    my $t = getc(I);
    return(0) if (!length($t));
    while ($t =~ /^\d$/) {
      $_ .= $t;
      $t  = getc(I);
    }
    my $hdr_flag  = $t;
    my $hdr_bytes = $_;
    $t            = getc(I);              # strip the space out of the file
    return(0) if (read(I, $_, $hdr_bytes) != $hdr_bytes);
    if ($hdr_flag ne '*') {
      $self->{_vars}{message_linecount} += (tr/\n//);
      $self->{_vars}{message_size}      += $hdr_bytes;
    }

    # mark (rb)?header_ vars as existing and store raw value.  They'll be
    # processed further in get_var() if needed
    my($v,$d) = split(/:/, $_, 2);
    $v = "header_" . lc($v);
    $self->{_vars}{$v} = $self->{_vars}{"b$v"} = $self->{_vars}{"r$v"} = undef;
    push(@{$self->{_vars_raw}{"r$v"}{vals}}, $d);
    $self->{_vars_raw}{"r$v"}{type} = $hdr_flag;
    $self->{_vars}{message_headers_raw} .= $_;
  }
  close(I);

  $self->{_vars}{message_body_size} =
      (stat($self->{_path}.'/'.$self->{_message}.'-D'))[7] - 19;
  if ($self->{_vars}{message_body_size} < 0) {
    $self->{_vars}{message_size} = 0;
    $self->{_vars}{message_body_missing} = 1;
  } else {
    $self->{_vars}{message_size} += $self->{_vars}{message_body_size} + 1;
  }

  $self->{_vars}{message_linecount} += $self->{_vars}{body_linecount};

  my $i = $self->{_vars}{message_size};
  if ($i == 0)          { $i = ""; }
  elsif ($i < 1024)     { $i = sprintf("%d",    $i);                    }
  elsif ($i < 10240)    { $i = sprintf("%.1fK", $i / 1024);             }
  elsif ($i < 1048576)  { $i = sprintf("%dK",   ($i+512)/1024);         }
  elsif ($i < 10485760) { $i = sprintf("%.1fM", $i/1048576);            }
  else                  { $i = sprintf("%dM",   ($i + 524288)/1048576); }
  $self->{_vars}{shown_message_size} = $i;

  return(1);
}

# mimic exim's host_extract_port function - receive a ref to a scalar,
# strip it of port, return port
sub _get_host_and_port {
  my $self = shift;
  my $host = shift; # scalar ref, be careful

  if ($$host =~ /^\[([^\]]+)\](?:\:(\d+))?$/) {
    $$host = $1;
    return($2 || 0);
  } elsif ($$host =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:\.(\d+))?$/) {
    $$host = $1;
    return($2 || 0);
  } elsif ($$host =~ /^([\d\:]+)(?:\.(\d+))?$/) {
    $$host = $1;
    return($2 || 0);
  }
  # implicit else
  return(0);
}

# honoring all formatting preferences, return a scalar variable of the
# information for the single message matching what exim -bp would show.
# We can print later if we want.
sub format_message {
  my $self = shift;
  my $o    = '';
  return if ($self->{_delivered});

  # define any vars we want to print out for this message.  The requests
  # can be regexps, and the defined vars can change for each message, so we
  # have to build this list for each message
  my @vars = ();
  if (@{$self->{_show_vars}}) {
    my %t = ();
    foreach my $e (@{$self->{_show_vars}}) {
      foreach my $v ($self->get_matching_vars($e)) {
        next if ($t{$v}); $t{$v}++; push(@vars, $v);
      }
    }
  }

  if ($self->{_output_idonly}) {
    $o .= $self->{_message};
    foreach my $v (@vars) { $o .= " $v='" . $self->get_var($v) . "'"; }
    $o .= "\n";
    return $o;
  } elsif ($self->{_output_vars_only}) {
    foreach my $v (@vars) { $o .= $self->get_var($v) . "\n"; }
    return $o;
  }

  if ($self->{_output_long} || $self->{_output_flatq}) {
    my $i = int($self->{_vars}{message_age} / 60);
    if ($i > 90) {
      $i = int(($i+30)/60);
      if ($i > 72) { $o .= sprintf "%2dd ", int(($i+12)/24); }
      else { $o .= sprintf "%2dh ", $i; }
    } else { $o .= sprintf "%2dm ", $i; }

    if ($self->{_output_flatq} && @vars) {
        $o .= join(';', map { "$_='".$self->get_var($_)."'" } (@vars)
                  );
    } else {
      $o .= sprintf "%5s", $self->{_vars}{shown_message_size};
    }
    $o .= " ";
  }
  $o .= "$self->{_message} ";
  $o .= "From: " if ($self->{_output_brief});
  $o .= "<$self->{_vars}{sender_address}>";

  if ($self->{_output_long}) {
    $o .= " ($self->{_vars}{originator_login})"
        if ($self->{_vars}{sender_set_untrusted});

    # XXX exim contains code here to print spool format errors
    $o .= " *** frozen ***" if ($self->{_vars}{deliver_freeze});
    $o .= "\n";

    foreach my $v (@vars) {
      $o .= sprintf "  %25s = '%s'\n", $v, $self->get_var($v);
    }

    foreach my $r (keys %{$self->{_recips}}) {
      next if ($self->{_del_tree}{$r} && $self->{_undelivered_only});
      $o .= sprintf "        %s %s\n", $self->{_del_tree}{$r} ? "D" : " ", $r;
    }
    if ($self->{_show_generated}) {
      foreach my $r (keys %{$self->{_del_tree}}) {
        next if ($self->{_recips}{$r});
        $o .= sprintf "       +D %s\n", $r;
      }
    }
  } elsif ($self->{_output_brief}) {
    my @r = ();
    foreach my $r (keys %{$self->{_recips}}) {
      next if ($self->{_del_tree}{$r});
      push(@r, $r);
    }
    $o .= " To: " . join(';', @r);
    if (scalar(@vars)) {
      $o .= " Vars: ".join(';',map { "$_='".$self->get_var($_)."'" } (@vars));
    }
  } elsif ($self->{_output_flatq}) {
    $o .= " *** frozen ***" if ($self->{_vars}{deliver_freeze});
    my @r = ();
    foreach my $r (keys %{$self->{_recips}}) {
      next if ($self->{_del_tree}{$r});
      push(@r, $r);
    }
    $o .= " " . join(' ', @r);
  }

  $o .= "\n";
  return($o);
}

sub print_message {
  my $self = shift;
  my $fh   = shift || \*STDOUT;
  return if ($self->{_delivered});

  print $fh $self->format_message();
}

sub dump {
  my $self = shift;

  foreach my $k (sort keys %$self) {
    my $r = ref($self->{$k});
    if ($r eq 'ARRAY') {
      printf "%20s <<EOM\n", $k;
      print @{$self->{$k}}, "EOM\n";
    } elsif ($r eq 'HASH') {
      printf "%20s <<EOM\n", $k;
      foreach (sort keys %{$self->{$k}}) {
        printf "%20s %s\n", $_, $self->{$k}{$_};
      }
      print "EOM\n";
    } else {
      printf "%20s %s\n", $k, $self->{$k};
    }
  }
}

} # BEGIN

sub ext_usage {
  if ($ARGV[0] =~ /^--help$/i) {
    require Config;
    $ENV{PATH} .= ":" unless $ENV{PATH} eq "";
    $ENV{PATH} = "$ENV{PATH}$Config::Config{'installscript'}";
    #exec("perldoc", "-F", "-U", $0) || exit 1;
    $< = $> = 1 if ($> == 0 || $< == 0);
    exec("perldoc", $0) || exit 1;
    # make parser happy
    %Config::Config = ();
  } elsif ($ARGV[0] =~ /^--version$/i) {
    print "$p_name version $p_version\n\n$p_cp\n";
  } else {
    return;
  }

  exit(0);
}

__END__

=head1 NAME

exipick - selectively display messages from an Exim queue

=head1 SYNOPSIS

exipick [<options>] [<criterion> [<criterion> ...]]

=head1 DESCRIPTION

exipick is a tool to display messages in an Exim queue.  It is very similar to exiqgrep and is, in fact, a drop in replacement for exiqgrep.  exipick allows you to select messages to be displayed using any piece of data stored in an Exim spool file.  Matching messages can be displayed in a variety of formats.

=head1 QUICK START

Delete every frozen message from queue:
    exipick -zi | xargs exim -Mrm

Show only messages which have not yet been virus scanned:
    exipick '$received_protocol ne virus-scanned'

Run the queue in a semi-random order:
    exipick -i --random | xargs exim -M

Show the count and total size of all messages which either originated from localhost or have a received protocol of 'local':
    exipick --or --size --bpc \
            '$sender_host_address eq 127.0.0.1' \
            '$received_protocol eq local'

Display all messages received on the MSA port, ordered first by the sender's email domain and then by the size of the emails:
    exipick --sort sender_address_domain,message_size \
            '$received_port == 587'

Display only messages whose every recipient is in the example.com domain, also listing the IP address of the sending host:
    exipick --show-vars sender_host_address \
            '$each_recipients = example.com'

Same as above, but show values for all defined variables starting with sender_ and the number of recipients:
    exipick --show-vars ^sender_,recipients_count \
            '$each_recipients = example.com'

=head1 OPTIONS

=over 4

=item --and

Display messages matching all criteria (default)

=item -b

Display messages in brief format (exiqgrep)

=item -bp

Display messages in standard mailq format (default)

=item -bpa

Same as -bp, show generated addresses also (exim)

=item -bpc

Show a count of matching messages (exim)

=item -bpr

Same as '-bp --unsorted' (exim)

=item -bpra

Same as '-bpr --unsorted' (exim)

=item -bpru

Same as '-bpu --unsorted' (exim)

=item -bpu

Same as -bp, but only show undelivered messages (exim)

=item -c

Show a count of matching messages (exiqgrep)

=item --caseful

Make operators involving '=' honor case

=item --charset

Override the default local character set for $header_ decoding

=item -f <regexp>

Same as '$sender_address = <regexp>' (exiqgrep)

=item --flatq

Use a single-line output format

=item --freeze <cache file>

Save queue information in an quickly retrievable format

=item --help

Display this output

=item -i

Display only the message IDs (exiqgrep)

=item -l

Same as -bp (exiqgrep)

=item --not

Negate all tests.

=item -o <seconds>

Same as '$message_age > <seconds>' (exiqgrep)

=item --or

Display messages matching any criteria

=item -R

Same as --reverse (exiqgrep)

=item -r <regexp>

Same as '$recipients = <regexp>' (exiqgrep)

=item --random

Display messages in random order

=item --reverse

Display messages in reverse order

=item -s <string>

Same as '$shown_message_size eq <string>' (exiqgrep)

=item --spool <path>

Set the path to the exim spool to use

=item --show-rules

Show the internal representation of each criterion specified

=item --show-tests

Show the result of each criterion on each message

=item --show-vars <variable>[,<variable>...]

Show the value for <variable> for each displayed message.  <variable> will be a regular expression if it begins with a circumflex.

=item --size

Show the total bytes used by each displayed message

=item --thaw <cache file>

Read queue information cached from a previous --freeze run

=item --sort <variable>[,<variable>...]

Display matching messages sorted according to <variable>

=item --unsorted

Do not apply any sorting to output

=item --version

Display the version of this command

=item -x

Same as '!$deliver_freeze' (exiqgrep)

=item -y

Same as '$message_age < <seconds>' (exiqgrep)

=item -z

Same as '$deliver_freeze' (exiqgrep)

=back

=head1 CRITERIA

Exipick decides which messages to display by applying a test against each message.  The rules take the general form of 'VARIABLE OPERATOR VALUE'.  For example, '$message_age > 60'.  When exipick is deciding which messages to display, it checks the $message_age variable for each message.  If a message's age is greater than 60, the message will be displayed.  If the message's age is 60 or less seconds, it will not be displayed.

Multiple criteria can be used.  The order they are specified does not matter.  By default all criteria must evaluate to true for a message to be displayed.  If the --or option is used, a message is displayed as long as any of the criteria evaluate to true.

See the VARIABLES and OPERATORS sections below for more details

=head1 OPERATORS

=over 4

=item BOOLEAN

Boolean variables are checked simply by being true or false.  There is no real operator except negation.  Examples of valid boolean tests:
  '$deliver_freeze'
  '!$deliver_freeze'

=item NUMERIC

Valid comparisons are <, <=, >, >=, ==, and !=.  Numbers can be integers or floats.  Any number in a test suffixed with d, h, m, s, M, K, or B will be mulitplied by 86400, 3600, 60, 1, 1048576, 1024, or 1 respectively.  Examples of valid numeric tests:
  '$message_age >= 3d'
  '$local_interface == 587'
  '$message_size < 30K'

=item STRING

The string operators are =, eq, ne, =~, and !~.  With the exception of '=', the operators all match the functionality of the like-named perl operators.  eq and ne match a string exactly.  !~, =~, and = apply a perl regular expression to a string.  The '=' operator behaves just like =~ but you are not required to place // around the regular expression.  Examples of valid string tests:
  '$received_protocol eq esmtp'
  '$sender_address = example.com'
  '$each_recipients =~ /^a[a-z]{2,3}@example.com$/'

=item NEGATION

There are many ways to negate tests, each having a reason for existing.  Many tests can be negated using native operators.  For instance, >1 is the opposite of <=1 and eq and ne are opposites.  In addition, each individual test can be negated by adding a ! at the beginning of the test.  For instance, '!$acl_m1 =~ /^DENY$/' is the same as '$acl_m1 !~ /^DENY$/'.  Finally, every test can be specified by using the command line argument --not.  This is functionally equivilant to adding a ! to the beginning of every test.

=back

=head1 VARIABLES

With a few exceptions the available variables match Exim's internal expansion variables in both name and exact contents.  There are a few notable additions and format deviations which are noted below.  Although a brief explanation is offered below, Exim's spec.txt should be consulted for full details.  It is important to remember that not every variable will be defined for every message.  For example, $sender_host_port is not defined for messages not received from a remote host.

Internally, all variables are represented as strings, meaning any operator will work on any variable.  This means that '$sender_host_name > 4' is a legal criterion, even if it does not produce meaningful results.  Variables in the list below are marked with a 'type' to help in choosing which types of operators make sense to use.

  Identifiers
    B - Boolean variables
    S - String variables
    N - Numeric variables
    . - Standard variable matching Exim's content definition
    # - Standard variable, contents differ from Exim's definition
    + - Non-standard variable

=over 4

=item S . $acl_c0-$acl_c9, $acl_m0-$acl_m9

User definable variables.

=item B + $allow_unqualified_recipient

TRUE if unqualified recipient addresses are permitted in header lines.

=item B + $allow_unqualified_sender

TRUE if unqualified sender addresses are permitted in header lines.

=item S . $authenticated_id

Optional saved information from authenticators, or the login name of the calling process for locally submitted messages.

=item S . $authenticated_sender

The value of AUTH= param for smtp messages, or a generated value from the calling processes login and qualify domain for locally submitted messages.

=item S . $bheader_*, $bh_*

Value of the header(s) with the same name with any RFC2047 words decoded if present.  See section 11.5 of Exim's spec.txt for full details.

=item S + $bmi_verdicts

The verdict string provided by a Brightmail content scan

=item N . $body_linecount

The number of lines in the message's body.

=item N . $body_zerocount

The number of binary zero bytes in the message's body.

=item B + $deliver_freeze

TRUE if the message is currently frozen.

=item N + $deliver_frozen_at

The epoch time at which message was frozen.

=item B + $dont_deliver

TRUE if, under normal circumstances, Exim will not try to deliver the message.

=item S + $each_recipients

This is a psuedo variable which allows you to apply a test against each address in $recipients individually.  Whereas '$recipients =~ /@aol.com/' will match if any recipient address contains aol.com, '$each_recipients =~ /@aol.com$/' will only be true if every recipient matches that pattern.  Note that this obeys --and or --or being set.  Using it with --or is very similar to just matching against $recipients, but with the added benefit of being able to use anchors at the beginning and end of each recipient address.

=item S + $each_recipients_del

Like $each_recipients, but for $recipients_del

=item S + $each_recipients_undel

Like $each_recipients, but for $recipients_undel

=item B . $first_delivery

TRUE if the message has never been deferred.

=item S . $header_*, $h_*

This will always match the contents of the corresponding $bheader_* variable currently (the same behaviour Exim displays when iconv is not installed).

=item B . $host_lookup_deferred

TRUE if there was an attempt to look up the host's name from its IP address, but an error occurred that during the attempt.

=item B . $host_lookup_failed

TRUE if there was an attempt to look up the host's name from its IP address, but the attempt returned a negative result.

=item B + $local_error_message

TRUE if the message is a locally-generated error message.

=item S . $local_scan_data

The text returned by the local_scan() function when a message is received.

=item B . $manually_thawed

TRUE when the message has been manually thawed.

=item N . $message_age

The number of seconds since the message was received.

=item S # $message_body

The message's body.  Unlike Exim's variable of the same name, this variable contains the entire message body.  Newlines and nulls are replaced by spaces.

=item B + $message_body_missing

TRUE is a message's spool data file (-D file) is missing or unreadable.

=item N . $message_body_size

The size of the body in bytes.

=item S . $message_exim_id, $message_id

The unique message id that is used by Exim to identify the message.  $message_id is deprecated as of Exim 4.53.

=item S . $message_headers

A concatenation of all the header lines except for lines added by routers or transports.  RFC2047 decoding is performed

=item S . $message_headers_raw

A concatenation of all the header lines except for lines added by routers or transports.  No decoding or translation is performed.

=item N . $message_linecount

The number of lines in the entire message (body and headers).

=item N . $message_size

The size of the message in bytes.

=item N . $originator_gid

The group id under which the process that called Exim was running as when the message was received.

=item S + $originator_login

The login of the process which called Exim.

=item N . $originator_uid

The user id under which the process that called Exim was running as when the message was received.

=item S . $received_ip_address, $interface_address

The address of the local IP interface for network-originated messages.  $interface_address is deprecated as of Exim 4.64

=item N . $received_port, $interface_port

The local port number if network-originated messages.  $interface_port is deprecated as of Exim 4.64

=item N . $received_count

The number of Received: header lines in the message.

=item S . $received_protocol

The name of the protocol by which the message was received.

=item N . $received_time

The epoch time at which the message was received.

=item S # $recipients

The list of envelope recipients for a message.  Unlike Exim's version, this variable always contains every recipient of the message.  The recipients are seperated by a comma and a space.  See also $each_recipients.

=item N . $recipients_count

The number of envelope recipients for the message.

=item S + $recipients_del

The list of delivered envelope recipients for a message.  This non-standard variable is in the same format as $recipients and contains the list of already-delivered recipients including any generated addresses.  See also $each_recipients_del.

=item N + $recipients_del_count

The number of envelope recipients for the message which have already been delivered.  Note that this is the count of original recipients to which the message has been delivered.  It does not include generated addresses so it is possible that this number will be less than the number of addresses in the $recipients_del string.

=item S + $recipients_undel

The list of undelivered envelope recipients for a message.  This non-standard variable is in the same format as $recipients and contains the list of undelivered recipients.  See also $each_recipients_undel.

=item N + $recipients_undel_count

The number of envelope recipients for the message which have not yet been delivered.

=item S . $reply_address

The contents of the Reply-To: header line if one exists and it is not empty, or otherwise the contents of the From: header line.

=item S . $rheader_*, $rh_*

The value of the message's header(s) with the same name.  See section 11.5 of Exim's spec.txt for full description.

=item S . $sender_address

The sender's address that was received in the message's envelope.  For bounce messages, the value of this variable is the empty string.

=item S . $sender_address_domain

The domain part of $sender_address.

=item S . $sender_address_local_part

The local part of $sender_address.

=item S . $sender_helo_name

The HELO or EHLO value supplied for smtp or bsmtp messages.

=item S . $sender_host_address

The remote host's IP address.

=item S . $sender_host_authenticated

The name of the authenticator driver which successfully authenticated the client from which the message was received.

=item S . $sender_host_name

The remote host's name as obtained by looking up its IP address.

=item N . $sender_host_port

The port number that was used on the remote host for network-originated messages.

=item S . $sender_ident

The identification received in response to an RFC 1413 request for remote messages, the login name of the user that called Exim for locally generated messages.

=item B + $sender_local

TRUE if the message was locally generated.

=item B + $sender_set_untrusted

TRUE if the envelope sender of this message was set by an untrusted local caller.

=item S + $shown_message_size

This non-standard variable contains the formatted size string.  That is, for a message whose $message_size is 66566 bytes, $shown_message_size is 65K.

=item S . $smtp_active_hostname

The value of the active host name when the message was received, as specified by the "smtp_active_hostname" option.

=item S . $spam_score

The spam score of the message, for example '3.4' or '30.5'.  (Requires exiscan or WITH_CONTENT_SCAN)

=item S . $spam_score_int

The spam score of the message, multiplied by ten, as an integer value.  For instance '34' or '305'.  (Requires exiscan or WITH_CONTENT_SCAN)

=item B . $tls_certificate_verified

TRUE if a TLS certificate was verified when the message was received.

=item S . $tls_cipher

The cipher suite that was negotiated for encrypted SMTP connections.

=item S . $tls_peerdn

The value of the Distinguished Name of the certificate if Exim is configured to request one

=item N + $warning_count

The number of delay warnings which have been sent for this message.

=back

=head1 CONTACT

=over 4

=item EMAIL: proj-exipick@jetmore.net

=item HOME: jetmore.org/john/code/#exipick

=back

=cut

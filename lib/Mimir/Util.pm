package Mimir::Util;
use strict;
use warnings;
use Exporter 'import';
use POSIX ();
use Digest::MD5 ();

our @EXPORT_OK = qw(class_basename snake_case pluralize uniq now_string index_name);

sub class_basename { my $c = shift; $c =~ s/^.*:://; return $c }

sub snake_case {
  my $s = shift;
  $s =~ s/([a-z\d])([A-Z])/$1_$2/g;
  $s =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
  return lc $s;
}

my %IRREGULAR = (
  person => 'people', man => 'men', woman => 'women', child => 'children',
  mouse => 'mice', foot => 'feet', tooth => 'teeth', goose => 'geese',
);
my %UNCOUNTABLE = map { $_ => 1 } qw(equipment information rice money species series fish sheep news);

sub pluralize {
  my $w = shift;
  return $w if $UNCOUNTABLE{lc $w};
  my ($pre, $last) = $w =~ /^(.*_)?([^_]+)$/;
  $pre //= '';
  my $l = lc $last;
  return $pre . $IRREGULAR{$l} if $IRREGULAR{$l};
  if    ($last =~ /(?:s|x|z|ch|sh)$/i) { $last .= 'es' }
  elsif ($last =~ /[^aeiou]y$/i)       { $last =~ s/y$/ies/i }
  else                                 { $last .= 's' }
  return $pre . $last;
}

sub uniq { my %s; return grep { defined $_ && !$s{$_}++ } @_ }

sub now_string { return POSIX::strftime('%Y-%m-%d %H:%M:%S', gmtime) }

sub index_name {
  my ($table, $cols, $type) = @_;
  my $n = lc join '_', $table, @$cols, $type;
  $n =~ s/[^a-z0-9_]+/_/g;
  $n = substr($n, 0, 50) . '_' . substr(Digest::MD5::md5_hex($n), 0, 8) if length $n > 60;
  return $n;
}

1;

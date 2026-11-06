package Mimir::Relation;
use Moo;
use Carp ();
use Scalar::Util qw(blessed refaddr);
use Mojo::Collection;

our $AUTOLOAD;

has parent  => (is => 'ro', required => 1);
has related => (is => 'ro', required => 1);        # related model class
has query   => (is => 'lazy');

sub _build_query {
  my $s = shift;
  my $q = $s->related->query;
  $s->add_constraints($q);
  return $q;
}

sub add_constraints { }
sub _post { }                     # hook: post-process loaded models (arrayref)

sub get {
  my $s = shift;
  my $c = $s->query->get(@_);
  $s->_post([@$c]);
  return $c;
}

sub first {
  my $s = shift;
  my $m = $s->query->first(@_);
  $s->_post([$m]) if $m;
  return $m;
}

# fetch related models whose $column is in @keys (in chunks, to keep placeholder counts sane)
sub _fetch_in {
  my ($s, $column, $keys, $cb, $prepare) = @_;
  my @all;
  my @k = @$keys;
  while (my @chunk = splice @k, 0, 500) {
    my $q = $s->related->query;
    $prepare->($q) if $prepare;
    $q->where_in($column, \@chunk);
    $cb->($q) if $cb;
    push @all, @{$q->get};
  }
  return \@all;
}

sub _keys {
  my ($s, $models, $attr) = @_;
  my %seen;
  return [grep { defined $_ && !$seen{$_}++ } map { $_->attributes->{$attr} } @$models];
}

sub AUTOLOAD {
  my $s = shift;
  (my $n = $AUTOLOAD) =~ s/.*:://;
  return if $n eq 'DESTROY';
  my $q = $s->query;
  Carp::croak(qq{Can't locate method "$n" on } . ref $s)
    unless $q->can($n) || $s->related->can("scope_$n");
  my $r = $q->$n(@_);
  return blessed $r && refaddr $r == refaddr $q ? $s : $r;
}

{
  no strict 'refs'; no warnings 'redefine';
  *{__PACKAGE__ . '::with'} = sub { my $s = shift; $s->include(@_) };   # Moo exports `with`; forward to the query instead
}

1;

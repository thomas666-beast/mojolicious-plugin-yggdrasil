package Yggdrasil;
use Moo;
use Carp ();
use Yggdrasil::Connection;

our $VERSION = '0.01';
my $INSTANCE;

has connections      => (is => 'rw', default => sub { +{} });
has default          => (is => 'rw', default => sub { 'default' });
has model_namespaces => (is => 'rw', default => sub { [] });
has migration_paths  => (is => 'rw', default => sub { +{} });
has logger           => (is => 'rw');
has _pool            => (is => 'ro', default => sub { +{} });
has _models          => (is => 'ro', default => sub { +{} });

sub init         { my $class = shift; my $m = $class->new(@_); $INSTANCE = $m; return $m }
sub set_instance { $INSTANCE = $_[1] }
sub instance     { $INSTANCE }

sub connection {
  my ($s, $name) = @_;
  $name //= $s->default;
  return $s->_pool->{$name} //= do {
    my $cfg = $s->connections->{$name}
      or Carp::croak(qq{Yggdrasil: unknown connection "$name"});
    Yggdrasil::Connection->new(name => $name, config => $cfg, logger => $s->logger);
  };
}
sub db { shift->connection(@_) }

sub table { my ($s, $t, $conn) = @_; $s->connection($conn)->table($t) }

sub schema {
  my ($s, $conn) = @_;
  require Yggdrasil::Schema::Builder;
  Yggdrasil::Schema::Builder->new(connection => $s->connection($conn));
}

sub migrator {
  my ($s, $conn, %o) = @_;
  require Yggdrasil::Migrator;
  $conn //= $s->default;
  my $p = $o{paths} // $s->migration_paths->{$conn} // [];
  $p = [$p] unless ref $p;
  Yggdrasil::Migrator->new(connection => $s->connection($conn), paths => $p);
}

sub transaction { my ($s, $cb, $conn) = @_; $s->connection($conn)->transaction($cb) }

sub model {
  my ($s, $name) = @_;
  return $s->_models->{$name} //= $s->_resolve_model($name);
}

sub _resolve_model {
  my ($s, $name) = @_;
  my @cand = $name =~ /::/ ? ($name) : map {"${_}::$name"} @{$s->model_namespaces};
  for my $c (@cand) {
    return $c if $c->isa('Yggdrasil::Model');
    (my $f = "$c.pm") =~ s{::}{/}g;
    if (eval { require $f; 1 }) { return $c if $c->isa('Yggdrasil::Model') }
    else { die $@ unless $@ =~ /^Can't locate \Q$f\E/ }
  }
  Carp::croak(qq{Yggdrasil: model "$name" not found (looked for: @cand)});
}

sub disconnect_all { $_->disconnect for values %{$_[0]->_pool}; return }

1;

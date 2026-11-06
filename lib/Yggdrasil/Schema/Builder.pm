package Yggdrasil::Schema::Builder;
use Moo;
use Yggdrasil::Schema::Blueprint;

has connection => (is => 'ro', required => 1);

sub grammar { $_[0]->connection->grammar }

sub _build_bp {
  my ($s, $bp) = @_;
  $s->connection->statement($_) for $s->grammar->compile_blueprint($bp);
  return;
}

sub create {
  my ($s, $table, $cb) = @_;
  my $bp = Yggdrasil::Schema::Blueprint->new(table => $table, create => 1);
  $cb->($bp);
  $s->_build_bp($bp);
}

sub table {
  my ($s, $table, $cb) = @_;
  my $bp = Yggdrasil::Schema::Blueprint->new(table => $table, create => 0);
  $cb->($bp);
  $s->_build_bp($bp);
}

sub drop           { $_[0]->connection->statement($_[0]->grammar->compile_drop_table($_[1])); return }
sub drop_if_exists { $_[0]->connection->statement($_[0]->grammar->compile_drop_if_exists($_[1])); return }
sub rename         { $_[0]->connection->statement($_[0]->grammar->compile_rename($_[1], $_[2])); return }
sub raw            { my ($s, $sql, @b) = @_; $s->connection->statement($sql, @b) }

sub has_table {
  my ($s, $t) = @_;
  my ($sql, @b) = $s->grammar->compile_has_table($t);
  return @{$s->connection->select_all($sql, @b)} ? 1 : 0;
}

sub get_columns {
  my ($s, $t) = @_;
  my ($sql, @b) = $s->grammar->compile_columns($t);
  return map { $_->{name} } @{$s->connection->select_all($sql, @b)};
}

sub has_column {
  my ($s, $t, $c) = @_;
  return (grep { lc $_ eq lc $c } $s->get_columns($t)) ? 1 : 0;
}

sub get_tables {
  my $s = shift;
  return map { $_->{name} } @{$s->connection->select_all($s->grammar->compile_list_tables)};
}

sub drop_all_tables {
  my $s = shift;
  my $g = $s->grammar;
  my $c = $s->connection;
  my @tables = $s->get_tables;
  $c->statement($_) for $g->fk_checks_off;
  my $ok = eval { $c->statement($g->compile_drop_table($_)) for @tables; 1 };
  my $err = $@;
  $c->statement($_) for $g->fk_checks_on;
  die $err unless $ok;
  return scalar @tables;
}

1;

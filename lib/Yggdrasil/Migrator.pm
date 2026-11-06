package Yggdrasil::Migrator;
use Moo;
use Carp ();
use File::Basename ();
use File::Path ();
use File::Spec ();
use POSIX ();
use Scalar::Util qw(blessed);
use Yggdrasil::Schema::Builder;

has connection => (is => 'ro', required => 1);
has paths      => (is => 'ro', default => sub { [] });
has table      => (is => 'ro', default => sub { 'migrations' });
has _loaded    => (is => 'ro', default => sub { +{} });

sub schema { Yggdrasil::Schema::Builder->new(connection => $_[0]->connection) }
sub repo   { $_[0]->connection->table($_[0]->table) }

sub ensure_repository {
  my $s = shift;
  my $schema = $s->schema;
  return if $schema->has_table($s->table);
  $schema->create($s->table, sub {
    my $t = shift;
    $t->id;
    $t->string('migration');
    $t->integer('batch');
  });
}

# name => absolute path, for every *.pl in every configured path
sub files {
  my $s = shift;
  my %f;
  for my $dir (@{$s->paths}) {
    for my $file (glob File::Spec->catfile($dir, '*.pl')) {
      my ($n) = File::Basename::basename($file) =~ /^(.*)\.pl$/;
      $f{$n} = File::Spec->rel2abs($file);
    }
  }
  return \%f;
}

sub _ran_rows {
  my $s = shift;
  $s->ensure_repository;
  return $s->repo->order_by('batch')->order_by('id')->get;
}

sub ran { my $s = shift; [map { $_->{migration} } @{$s->_ran_rows}] }

sub status {
  my $s = shift;
  my %batch = map { $_->{migration} => $_->{batch} } @{$s->_ran_rows};
  my $files = $s->files;
  return [
    (map { { name => $_, ran => exists $batch{$_} ? 1 : 0, batch => $batch{$_}, missing => 0 } } sort keys %$files),
    (map { { name => $_, ran => 1, batch => $batch{$_}, missing => 1 } } grep { !exists $files->{$_} } sort keys %batch),
  ];
}

sub pending {
  my $s = shift;
  my %ran = map { $_ => 1 } @{$s->ran};
  my $files = $s->files;
  return [grep { !$ran{$_} } sort keys %$files];
}

sub _load {
  my ($s, $name) = @_;
  return $s->_loaded->{$name} //= do {
    my $file = $s->files->{$name} // Carp::croak("Mimir: migration file for '$name' not found");
    my $m = do $file;
    Carp::croak("Mimir: error in migration $name: $@") if $@;
    Carp::croak("Mimir: cannot read migration $name: $!") unless defined $m;
    Carp::croak("Mimir: migration $name must return { up => sub, down => sub }")
      unless blessed $m || (ref $m eq 'HASH' && ref $m->{up} eq 'CODE' && ref $m->{down} eq 'CODE');
    $m;
  };
}

sub _call {
  my ($s, $m, $dir) = @_;
  my @args = ($s->schema, $s->connection);
  return blessed $m ? $m->$dir(@args) : $m->{$dir}->(@args);
}

sub _tx {
  my ($s, $cb) = @_;
  return $s->connection->grammar->supports_ddl_transactions ? $s->connection->transaction($cb) : $cb->();
}

sub run {
  my ($s, %o) = @_;
  my @pending = @{$s->pending};
  return [] unless @pending;
  my $last = $s->repo->max('batch') // 0;
  my $batch = $o{step} ? undef : $last + 1;
  my @out;
  for my $name (@pending) {
    my $m = $s->_load($name);
    my $b = $batch // ++$last;
    if ($o{pretend}) {
      push @out, { migration => $name, queries => $s->connection->pretend(sub { $s->_call($m, 'up') }) };
      next;
    }
    $s->_tx(sub {
      $s->_call($m, 'up');
      $s->repo->insert({ migration => $name, batch => $b });
    });
    push @out, { migration => $name, batch => $b };
  }
  return \@out;
}

sub rollback {
  my ($s, %o) = @_;
  $s->ensure_repository;
  my @rows = @{$s->repo->order_by('batch', 'desc')->order_by('id', 'desc')->get};
  return [] unless @rows;
  if    ($o{all})  { }
  elsif ($o{step}) { splice @rows, $o{step} if @rows > $o{step} }
  else             { my $b = $rows[0]{batch}; @rows = grep { $_->{batch} == $b } @rows }
  my @out;
  for my $r (@rows) {
    my $m = $s->_load($r->{migration});
    if ($o{pretend}) {
      push @out, { migration => $r->{migration}, queries => $s->connection->pretend(sub { $s->_call($m, 'down') }) };
      next;
    }
    $s->_tx(sub {
      $s->_call($m, 'down');
      $s->repo->where(id => $r->{id})->delete;
    });
    push @out, { migration => $r->{migration}, batch => $r->{batch} };
  }
  return \@out;
}

sub reset   { $_[0]->rollback(all => 1) }
sub refresh { my $s = shift; $s->reset; $s->run(@_) }
sub fresh   { my $s = shift; $s->schema->drop_all_tables; $s->run(@_) }

sub make {
  my ($s, $name, %o) = @_;
  $name = lc $name;
  $name =~ s/[^a-z0-9]+/_/g;
  $name =~ s/^_|_$//g;
  Carp::croak('Mimir: migration name required') unless length $name;
  my $dir = $s->paths->[0] // Carp::croak('Mimir: no migration path configured');
  for my $n (keys %{$s->files}) { Carp::croak("Mimir: migration '$name' already exists") if $n =~ /^\d{4}_\d{2}_\d{2}_\d{6}_\Q$name\E$/ }
  File::Path::make_path($dir);
  my $file = File::Spec->catfile($dir, POSIX::strftime('%Y_%m_%d_%H%M%S', gmtime) . "_$name.pl");
  my ($create, $alter) = ($o{create}, $o{table});
  if (!$create && !$alter) {
    if    ($name =~ /^create_(\w+?)_table$/)         { $create = $1 }
    elsif ($name =~ /_(?:to|from|in)_(\w+?)_table$/) { $alter  = $1 }
  }
  open my $fh, '>:encoding(UTF-8)', $file or Carp::croak("Mimir: cannot write $file: $!");
  print $fh $s->_stub($name, $create, $alter);
  close $fh;
  return $file;
}

sub _stub {
  my ($s, $name, $create, $alter) = @_;
  my ($up, $down);
  if ($create) {
    $up   = "    \$schema->create('$create', sub {\n      my \$t = shift;\n      \$t->id;\n      \$t->timestamps;\n    });";
    $down = "    \$schema->drop_if_exists('$create');";
  }
  elsif ($alter) {
    $up   = "    \$schema->table('$alter', sub {\n      my \$t = shift;\n      # \$t->string('column_name')->nullable;\n    });";
    $down = "    \$schema->table('$alter', sub {\n      my \$t = shift;\n      # \$t->drop_column('column_name');\n    });";
  }
  else { $up = '    # ...'; $down = '    # ...' }
  return <<"EOT";
use strict;
use warnings;

# Migration: $name
return {
  up => sub {
    my (\$schema, \$db) = \@_;
$up
  },

  down => sub {
    my (\$schema, \$db) = \@_;
$down
  },
};
EOT
}

1;

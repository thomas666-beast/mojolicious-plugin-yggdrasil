package Mojolicious::Plugin::Yggdrasil;
use Mojo::Base 'Mojolicious::Plugin';
use Yggdrasil;

our $VERSION = '0.01';

sub register {
  my ($self, $app, $conf) = @_;
  $conf = { %{$app->config->{yggdrasil} // {}}, %{$conf // {}} };

  # one flat connection (driver/database/...) or a "connections" hash
  my $conns = $conf->{connections};
  unless ($conns) {
    my %c = %$conf;
    delete @c{qw(default models migrations migrate log connections)};
    $conns = { default => \%c } if %c;
  }
  die "Mojolicious::Plugin::Yggdrasil: no connection configured\n" unless $conns && %$conns;
  $conns = { map { $_ => { %{$conns->{$_}} } } keys %$conns };

  for my $c (values %$conns) {
    if (($c->{url} // '') =~ m{^sqlite3?:(?://)?(.*)$}i) {
      @$c{qw(driver database)} = ('sqlite', $1 eq '' ? ':memory:' : $1);
      delete $c->{url};
    }
    if (($c->{driver} // '') =~ /^sqlite/i && defined $c->{database}
      && $c->{database} ne ':memory:' && $c->{database} !~ m{^(?:/|[A-Za-z]:)}) {
      $c->{database} = $app->home->child($c->{database})->to_string;
    }
  }

  my $default = $conf->{default} // (exists $conns->{default} ? 'default' : (sort keys %$conns)[0]);

  my $class = ref $app;
  $class = 'main' if $class eq 'Mojolicious::Lite';
  my $models = $conf->{models} // ["${class}::Model"];
  $models = [$models] unless ref $models;

  my $mig = $conf->{migrations} // 'migrations';
  $mig = { $default => $mig } unless ref $mig eq 'HASH';
  my %paths;
  for my $name (keys %$conns) {
    my $p = $mig->{$name} // ($name eq $default ? 'migrations' : "migrations/$name");
    $paths{$name} = [map { m{^(?:/|[A-Za-z]:)} ? $_ : $app->home->child($_)->to_string } (ref $p ? @$p : $p)];
  }

  my $yggdrasil = Yggdrasil->init(
    connections => $conns, default => $default, model_namespaces => $models,
    migration_paths => \%paths, logger => ($conf->{log} ? $app->log : undef),
  );

  $app->helper(yggdrasil => sub { $yggdrasil });
  $app->helper(db    => sub { my ($c, $n) = @_; $yggdrasil->connection($n) });
  $app->helper(model => sub { my ($c, $n) = @_; $yggdrasil->model($n) });
  $app->helper(table => sub { my ($c, $t, $n) = @_; $yggdrasil->table($t, $n) });

  push @{$app->commands->namespaces}, 'Mojolicious::Plugin::Yggdrasil::Command';

  $yggdrasil->migrator($default)->run if $conf->{migrate};
  return $yggdrasil;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Yggdrasil - Eloquent-style ORM, query builder and migrations for Mojolicious

=head1 SYNOPSIS

  # Mojolicious::Lite / Mojolicious
  plugin 'Yggdrasil' => {
    default     => 'main',
    connections => {
      main    => { driver => 'sqlite', database => 'db/app.db' },
      reports => { url => 'postgresql://user:pass@localhost/reports' },
      legacy  => { driver => 'mysql', host => 'db1', database => 'old', username => 'u', password => 'p' },
    },
    models     => ['MyApp::Model'],
    migrations => 'migrations',
    log        => 1,
  };

  my $user  = $c->model('User')->find(1);
  my $rows  = $c->table('users')->where(active => 1)->order_by('name')->get;
  $c->yggdrasil->transaction(sub { ... });

  $ ./myapp.pl yggdrasil migrate

=head1 HELPERS

C<yggdrasil>, C<db>, C<model>, C<table>.

=head1 OPTIONS

C<connections>, C<default>, C<models>, C<migrations>, C<migrate>, C<log>.
See the README for the full documentation.

=cut

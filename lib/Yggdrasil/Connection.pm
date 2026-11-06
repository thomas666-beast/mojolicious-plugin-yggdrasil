package Yggdrasil::Connection;
use Moo;
use Carp ();
use DBI;
use Scalar::Util qw(blessed);
use Time::HiRes ();
use Yggdrasil::Exception;

my %ALIAS = (
  sqlite => 'sqlite', sqlite3 => 'sqlite',
  mysql => 'mysql', mariadb => 'mysql',
  pg => 'pg', postgres => 'pg', postgresql => 'pg', pgsql => 'pg',
);
my %GRAMMAR = (sqlite => 'SQLite', mysql => 'MySQL', pg => 'Pg');

has name      => (is => 'ro', default => sub { 'default' });
has config    => (is => 'ro', required => 1);
has logger    => (is => 'rw');
has query_log => (is => 'rw');
has driver    => (is => 'lazy');
has grammar   => (is => 'lazy');
has _dbh      => (is => 'rw');
has _pid      => (is => 'rw');
has _used     => (is => 'rw', default => sub { 0 });
has _level    => (is => 'rw', default => sub { 0 });
has _pretend  => (is => 'rw');

sub _build_driver {
  my $s = shift;
  my $c = $s->config;
  my $d = $c->{driver};
  ($d) = $c->{url} =~ m{^([a-z0-9]+):}i if !$d && $c->{url};
  ($d) = $c->{dsn} =~ /^dbi:(\w+)/i     if !$d && $c->{dsn};
  Carp::croak('Yggdrasil: connection config needs a driver (sqlite, mysql or pg)') unless $d;
  return $ALIAS{lc $d} // Carp::croak(qq{Yggdrasil: unsupported driver "$d" (use sqlite, mysql or pg)});
}

sub _build_grammar {
  my $s = shift;
  my $class = 'Yggdrasil::Grammar::' . $GRAMMAR{$s->driver};
  (my $f = "$class.pm") =~ s{::}{/}g;
  require $f;
  return $class->new(config => $s->config);
}

# ---- connecting ---------------------------------------------------------

sub _parse_url {
  my ($s, $url) = @_;
  my %p;
  if ($url =~ m{^sqlite3?:(?://)?(.*)$}i) {
    $p{database} = $1 eq '' ? ':memory:' : $1;
    return \%p;
  }
  $url =~ m{^[a-z0-9+]+://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?#]*)(?::(\d+))?(?:/([^?#]*))?(?:\?.*)?$}i
    or Carp::croak("Yggdrasil: cannot parse url '$url'");
  my %raw = (username => $1, password => $2, host => $3, port => $4, database => $5);
  for my $k (keys %raw) {
    next unless defined $raw{$k} && length $raw{$k};
    (my $v = $raw{$k}) =~ s/%([0-9a-f]{2})/chr hex $1/gie;
    $p{$k} = $v;
  }
  return \%p;
}

sub _connect_info {
  my $s = shift;
  my ($c, $d) = ($s->config, $s->driver);
  my %p = map { $_ => $c->{$_} } grep { defined $c->{$_} } qw(host port database username password socket);
  %p = (%{$s->_parse_url($c->{url})}, %p) if $c->{url};

  my $dsn = $c->{dsn};
  unless ($dsn) {
    Carp::croak('Yggdrasil: connection config needs a database') unless defined $p{database};
    if ($d eq 'sqlite') { $dsn = "dbi:SQLite:dbname=$p{database}" }
    elsif ($d eq 'mysql') {
      $dsn = "dbi:mysql:database=$p{database}";
      $dsn .= ";host=$p{host}"           if $p{host};
      $dsn .= ";port=$p{port}"           if $p{port};
      $dsn .= ";mysql_socket=$p{socket}" if $p{socket};
    }
    else {
      $dsn = "dbi:Pg:dbname=$p{database}";
      $dsn .= ";host=$p{host}" if $p{host};
      $dsn .= ";port=$p{port}" if $p{port};
    }
  }
  my %attr = (RaiseError => 1, PrintError => 0, AutoCommit => 1);
  unless ($dsn =~ /MariaDB/i) {
    %attr = (%attr,
      $d eq 'sqlite' ? (sqlite_unicode => 1)
    : $d eq 'mysql'  ? (mysql_enable_utf8mb4 => 1)
    :                  (pg_enable_utf8 => 1));
  }
  %attr = (%attr, %{$c->{options} // {}});
  return ($dsn, $p{username}, $p{password}, \%attr);
}

sub _connect {
  my $s = shift;
  my $dbh = DBI->connect($s->_connect_info)
    or Yggdrasil::Exception->throw(message => "Yggdrasil: cannot connect to '" . $s->name . "': " . ($DBI::errstr // 'unknown error'), type => 'connection');
  $s->_after_connect($dbh);
  $s->_dbh($dbh);
  $s->_pid($$);
  $s->_level(0);
  return $dbh;
}

sub _after_connect {
  my ($s, $dbh) = @_;
  my ($c, $d) = ($s->config, $s->driver);
  if ($d eq 'sqlite') {
    my %pr = (foreign_keys => 'ON', busy_timeout => 5000, %{$c->{pragmas} // {}});
    for my $k (sort keys %pr) {
      Carp::croak("Yggdrasil: invalid pragma '$k=$pr{$k}'") unless $k =~ /^\w+$/ && $pr{$k} =~ /^[\w.-]+$/;
      $dbh->do("pragma $k = $pr{$k}");
    }
  }
  elsif ($d eq 'mysql') {
    $dbh->do('set time_zone = ' . $dbh->quote($c->{timezone})) if $c->{timezone};
  }
  else {
    if (defined(my $sp = $c->{search_path})) {
      Carp::croak('Yggdrasil: invalid search_path') unless $sp =~ /^[\w,\s".\$-]+$/;
      $dbh->do("set search_path to $sp");
    }
    $dbh->do('set time zone ' . $dbh->quote($c->{timezone})) if $c->{timezone};
  }
  $c->{on_connect}->($dbh) if $c->{on_connect};
}

sub dbh {
  my $s = shift;
  my $dbh = $s->_dbh;
  if ($dbh && $s->_pid != $$) {       # forked: never touch the parent's socket
    $dbh->{InactiveDestroy} = 1;
    $dbh = undef;
    $s->_dbh(undef);
  }
  $dbh = undef if $dbh && !$dbh->{Active};
  if ($dbh && !$s->_level && time - $s->_used > ($s->config->{ping_interval} // 60)) {
    $dbh = undef unless $dbh->ping;
  }
  $dbh ||= $s->_connect;
  $s->_used(time);
  return $dbh;
}

sub disconnect {
  my $s = shift;
  my $dbh = $s->_dbh;
  $dbh->disconnect if $dbh && $s->_pid == $$;
  $s->_dbh(undef);
  return;
}

# ---- executing ----------------------------------------------------------

sub _fmt_bind { join ', ', map { defined $_ ? $_ : 'NULL' } @{$_[0]} }

sub _log {
  my ($s, $sql, $bind, $ms) = @_;
  push @{$s->query_log}, { query => $sql, bindings => [@$bind], time => $ms } if $s->query_log;
  my $l = $s->logger or return;
  my $msg = sprintf '[yggdrasil:%s] %s [%s] (%.2fms)', $s->name, $sql, _fmt_bind($bind), $ms;
  if (ref $l eq 'CODE') { $l->($msg, $sql, $bind, $ms) }
  elsif (blessed $l && $l->can('debug')) { $l->debug($msg) }
}

sub _run {
  my ($s, $sql, $bind, $code, $pretend_ret) = @_;
  if (my $p = $s->_pretend) {
    push @$p, { query => $sql, bindings => [@$bind] };
    return $pretend_ret;
  }
  my $t0 = [Time::HiRes::gettimeofday];
  my $res;
  my $ok = eval { $res = $code->($s->dbh); 1 };
  my $err = $@;
  $s->_log($sql, $bind, Time::HiRes::tv_interval($t0) * 1000);
  unless ($ok) {
    die $err if ref $err;
    Yggdrasil::Exception->throw(message => "$err", type => 'query', sql => $sql, bindings => $bind);
  }
  return $res;
}

sub select_all {
  my ($s, $sql, @b) = @_;
  $s->_run($sql, \@b, sub { $_[0]->selectall_arrayref($sql, {Slice => {}}, @b) }, []);
}

sub select_one {
  my ($s, $sql, @b) = @_;
  return $s->select_all($sql, @b)->[0];
}

sub statement {
  my ($s, $sql, @b) = @_;
  my $n = $s->_run($sql, \@b, sub { $_[0]->do($sql, undef, @b) }, 0);
  return 0 + ($n // 0);
}

sub insert_get_id {
  my ($s, $sql, $bind, $table, $pk) = @_;
  return $s->_run($sql, $bind, sub {
    my $dbh = shift;
    if ($s->driver eq 'pg') {
      my $row = $dbh->selectrow_arrayref($sql, undef, @$bind);
      return $row ? $row->[0] : undef;
    }
    $dbh->do($sql, undef, @$bind);
    return $dbh->last_insert_id(undef, undef, $table, $pk);
  }, undef);
}

# ---- builders -----------------------------------------------------------

sub table {
  my ($s, $t) = @_;
  require Yggdrasil::Query;
  return Yggdrasil::Query->new(connection => $s, from => $t);
}

sub schema {
  my $s = shift;
  require Yggdrasil::Schema::Builder;
  return Yggdrasil::Schema::Builder->new(connection => $s);
}

# ---- transactions (nested ones use savepoints) -----------------------------

sub begin_transaction {
  my $s = shift;
  return if $s->_pretend;
  my $l = $s->_level;
  if ($l == 0) { $s->dbh->begin_work } else { $s->statement("savepoint yggdrasil_trans_$l") }
  $s->_level($l + 1);
}

sub commit {
  my $s = shift;
  return if $s->_pretend;
  my $l = $s->_level - 1;
  Carp::croak('Yggdrasil: commit without transaction') if $l < 0;
  if ($l == 0) { $s->dbh->commit } else { $s->statement("release savepoint yggdrasil_trans_$l") }
  $s->_level($l);
}

sub rollback {
  my $s = shift;
  return if $s->_pretend;
  my $l = $s->_level - 1;
  return if $l < 0;
  if ($l == 0) { $s->dbh->rollback } else { $s->statement("rollback to savepoint yggdrasil_trans_$l") }
  $s->_level($l);
}

sub transaction {
  my ($s, $cb) = @_;
  my $want = wantarray;
  $s->begin_transaction;
  my @ret;
  my $ok = eval {
    if ($want) { @ret = $cb->($s) } else { $ret[0] = $cb->($s) }
    1;
  };
  my $err = $@;
  unless ($ok) {
    eval { $s->rollback };
    die $err;
  }
  $s->commit;
  return $want ? @ret : $ret[0];
}

# ---- misc -----------------------------------------------------------------

sub pretend {
  my ($s, $cb) = @_;
  $s->_pretend([]);
  my $ok = eval { $cb->($s); 1 };
  my $err = $@;
  my $q = $s->_pretend;
  $s->_pretend(undef);
  die $err unless $ok;
  return $q;
}

sub enable_query_log  { $_[0]->query_log([]); $_[0] }
sub disable_query_log { $_[0]->query_log(undef); $_[0] }

1;

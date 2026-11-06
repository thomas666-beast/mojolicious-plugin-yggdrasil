package Mojolicious::Plugin::Yggdrasil::Command::mimir;
use Mojo::Base 'Mojolicious::Command';
use Getopt::Long qw(GetOptionsFromArray);
use File::Path ();
use File::Spec ();
use Yggdrasil::Util qw(class_basename snake_case pluralize);

has description => 'Run Mimir ORM commands (migrate, rollback, status, make:migration ...)';
has usage       => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;
  my $cmd = shift @args // '';
  my ($conn, $pretend, $step, $create, $table, $mig);
  Getopt::Long::Configure('no_ignore_case');
  GetOptionsFromArray(\@args,
    'c|connection=s' => \$conn, 'pretend' => \$pretend, 'step:i' => \$step,
    'create=s' => \$create, 'table=s' => \$table, 'm|migration' => \$mig,
  ) or die $self->usage;

  my $mimir = $self->app->mimir;
  my $out = sub { print @_, "\n" };
  my %o = (pretend => $pretend);
  $o{step} = $step || 1 if defined $step;

  if ($cmd eq 'migrate') {
    my $r = $mimir->migrator($conn)->run(%o);
    $out->($pretend ? 'Would run:' : 'Migrated:') if @$r;
    for my $m (@$r) {
      $out->("  $m->{migration}");
      $out->("      $_->{query}") for @{$m->{queries} || []};
    }
    $out->('Nothing to migrate.') unless @$r;
  }
  elsif ($cmd =~ /^(?:rollback|reset)$/) {
    my $r = $mimir->migrator($conn)->rollback(%o, ($cmd eq 'reset' ? (all => 1) : ()));
    $out->('Rolled back:') if @$r;
    for my $m (@$r) {
      $out->("  $m->{migration}");
      $out->("      $_->{query}") for @{$m->{queries} || []};
    }
    $out->('Nothing to roll back.') unless @$r;
  }
  elsif ($cmd eq 'refresh') {
    my $m = $mimir->migrator($conn);
    $m->reset;
    $out->('Migrated: ' . scalar @{$m->run}) ;
  }
  elsif ($cmd eq 'fresh') {
    my $r = $mimir->migrator($conn)->fresh;
    $out->('Dropped all tables and migrated ' . scalar(@$r) . ' migration(s).');
  }
  elsif ($cmd eq 'status') {
    my $rows = $mimir->migrator($conn)->status;
    $out->(sprintf '%-5s %-6s %s', 'Ran?', 'Batch', 'Migration');
    $out->(sprintf '%-5s %-6s %s%s', $_->{ran} ? 'Yes' : 'No', $_->{batch} // '-', $_->{name}, $_->{missing} ? '  (file missing)' : '') for @$rows;
  }
  elsif ($cmd eq 'make:migration') {
    my $name = shift @args or die "Usage: mimir make:migration NAME [--create TABLE | --table TABLE]\n";
    my $f = $mimir->migrator($conn)->make($name, create => $create, table => $table);
    $out->("Created $f");
  }
  elsif ($cmd eq 'make:model') {
    my $name = shift @args or die "Usage: mimir make:model NAME [--migration]\n";
    my $ns = $mimir->model_namespaces->[0] // 'App::Model';
    my $class = "${ns}::$name";
    my @p = split /::/, $class;
    my $file = File::Spec->catfile($self->app->home->child('lib')->to_string, @p[0 .. $#p - 1], "$p[-1].pm");
    die "$file already exists\n" if -e $file;
    File::Path::make_path((File::Spec->splitpath($file))[1]);
    open my $fh, '>:encoding(UTF-8)', $file or die "Cannot write $file: $!\n";
    print $fh <<"EOT";
package $class;
use Moo;
extends 'Yggdrasil::Model';

# sub table     { '${\ pluralize(snake_case($name)) }' }
# sub fillable  { [qw(name email)] }
# sub hidden    { [qw(password)] }
# sub casts     { { is_admin => 'bool', meta => 'json' } }
# with 'Yggdrasil::Role::SoftDeletes';

1;
EOT
    close $fh;
    $out->("Created $file");
    if ($mig) {
      my $t = pluralize(snake_case($name));
      $out->('Created ' . $mimir->migrator($conn)->make("create_${t}_table", create => $t));
    }
  }
  else { print $self->usage; return }
  return;
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: APPLICATION mimir COMMAND [OPTIONS]

    ./myapp.pl mimir migrate                 # run pending migrations
    ./myapp.pl mimir migrate --pretend       # show the SQL only
    ./myapp.pl mimir migrate --step          # one batch per migration
    ./myapp.pl mimir rollback [--step N]     # undo last batch (or last N migrations)
    ./myapp.pl mimir reset                   # undo everything
    ./myapp.pl mimir refresh                 # reset, then migrate
    ./myapp.pl mimir fresh                   # drop all tables, then migrate
    ./myapp.pl mimir status
    ./myapp.pl mimir make:migration create_posts_table
    ./myapp.pl mimir make:migration add_slug_to_posts_table
    ./myapp.pl mimir make:model Post --migration

  Options:
    -c, --connection NAME   Use another configured connection
        --pretend           Print SQL instead of executing (migrate/rollback)
        --step [N]          See above
        --create TABLE      make:migration: generate a create-table stub
        --table TABLE       make:migration: generate an alter-table stub
    -m, --migration         make:model: also generate a migration

=cut

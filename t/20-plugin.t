use strict;
use warnings;
use Test::More;

BEGIN {
  eval { require Mojolicious; require Test::Mojo; 1 } or plan skip_all => 'Mojolicious is required for plugin tests';
}

use File::Temp qw(tempdir);
use Mojolicious::Lite -signatures;
use Test::Mojo;

{
  package TestApp::Model::Note;
  use Moo;
  extends 'Mimir::Model';
  sub fillable { [qw(body)] }
}

my $dir = tempdir(CLEANUP => 1);
open my $fh, '>', "$dir/2026_01_01_000001_create_notes_table.pl" or die $!;
print $fh <<'M';
use strict; use warnings;
return {
  up   => sub { $_[0]->create('notes', sub { my $t = shift; $t->id; $t->string('body'); $t->timestamps }) },
  down => sub { $_[0]->drop_if_exists('notes') },
};
M
close $fh;

plugin Mimir => {
  connections => { default => { driver => 'sqlite', database => ':memory:' } },
  models      => ['TestApp::Model'],
  migrations  => $dir,
};

app->mimir->migrator->run;

post '/notes' => sub ($c) {
  my $n = $c->model('Note')->create({ body => $c->param('body') });
  $c->render(json => $n->to_hash);
};
get '/notes' => sub ($c) {
  $c->render(json => [map { $_->to_hash } @{$c->model('Note')->query->order_by('id')->get}]);
};
get '/count' => sub ($c) { $c->render(text => $c->table('notes')->count) };

my $t = Test::Mojo->new;
$t->post_ok('/notes' => form => { body => 'hello' })->status_is(200)->json_is('/body', 'hello');
$t->post_ok('/notes' => form => { body => 'world' })->status_is(200);
$t->get_ok('/notes')->status_is(200)->json_is('/1/body', 'world');
$t->get_ok('/count')->content_is('2');

# the "mimir" command
require Mojolicious::Plugin::Mimir::Command::mimir;
my $cmd = Mojolicious::Plugin::Mimir::Command::mimir->new(app => app);
my $out = '';
{
  open my $h, '>', \$out or die;
  local *STDOUT = $h;
  $cmd->run('status');
}
like $out, qr/create_notes_table/, 'status command lists migrations';

done_testing;

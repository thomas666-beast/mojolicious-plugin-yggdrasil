#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use lib 'lib';

plugin Mimir => {
  connections => { main => { driver => 'sqlite', database => 'db/app.db' } },
  models      => ['MyApp::Model'],
  migrations  => 'migrations',
  migrate     => 1,                 # run pending migrations on startup (handy in development)
  log         => 1,                 # log every query at debug level
};

get '/articles' => sub ($c) {
  my $page = $c->model('Article')->published->latest('id')->paginate(10, $c->param('page') // 1);
  $c->render(json => $page);
};

post '/articles' => sub ($c) {
  my $article = $c->model('Article')->create($c->req->json // {});   # mass assignment honours fillable()
  $c->render(json => $article, status => 201);
};

get '/articles/:id' => sub ($c) {
  my $article = $c->model('Article')->find_or_fail($c->param('id'));
  $article->increment('views');
  $c->render(json => $article);
};

# find_or_fail() / first_or_fail() throw Mimir::Exception (type "model_not_found") => answer 404
app->hook(around_action => sub ($next, $c, $action, $last) {
  my $r = eval { $next->() };
  if (my $err = $@) {
    die $err unless ref $err && $err->isa('Mimir::Exception') && $err->is_not_found;
    $c->render(json => { error => 'not found' }, status => 404);
    return undef;
  }
  return $r;
});

app->start;

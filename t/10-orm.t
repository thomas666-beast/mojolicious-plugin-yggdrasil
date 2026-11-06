use strict;
use warnings;
use Test::More;
BEGIN { eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is required' }
use File::Temp qw(tempdir);
use JSON::PP ();
use Yggdrasil;

# ---------------------------------------------------------------- models
{
  package TestApp::Model::User;
  use Moo;
  extends 'Yggdrasil::Model';
  has hook_log => (is => 'ro', default => sub { [] });
  sub fillable { [qw(name email age is_admin settings password)] }
  sub hidden   { ['password'] }
  sub casts    { { is_admin => 'bool', settings => 'json', age => 'int' } }
  sub posts    { $_[0]->has_many('Post') }
  sub profile  { $_[0]->has_one('Profile') }
  sub roles    { $_[0]->belongs_to_many('Role') }
  sub scope_adults { my ($class, $q) = @_; $q->where('age', '>=', 18) }
  sub set_email_attribute { lc $_[1] }
  sub get_name_attribute  { ucfirst $_[1] }
  sub appends { ['shout'] }
  sub get_shout_attribute { uc($_[0]->attributes->{name}) . '!' }
  before saving  => sub { push @{$_[0]->hook_log}, 'saving' };
  after  created => sub { push @{$_[0]->hook_log}, 'created' };
  after  updated => sub { push @{$_[0]->hook_log}, 'updated' };

  package TestApp::Model::Post;
  use Moo;
  extends 'Yggdrasil::Model';
  with 'Yggdrasil::Role::SoftDeletes';
  sub fillable { [qw(title votes published)] }
  sub casts    { { published => 'bool' } }
  sub user     { $_[0]->belongs_to('User') }
  sub comments { $_[0]->has_many('Comment') }

  package TestApp::Model::Comment;
  use Moo;
  extends 'Yggdrasil::Model';
  sub fillable { [qw(body)] }
  sub post { $_[0]->belongs_to('Post') }

  package TestApp::Model::Profile;
  use Moo;
  extends 'Yggdrasil::Model';
  sub fillable { [qw(bio)] }
  sub user { $_[0]->belongs_to('User') }

  package TestApp::Model::Role;
  use Moo;
  extends 'Yggdrasil::Model';
  sub fillable { [qw(name)] }
  sub users { $_[0]->belongs_to_many('User') }
}

# ---------------------------------------------------------------- migrations
my $dir = tempdir(CLEANUP => 1);
sub mig { my ($n, $body) = @_; open my $fh, '>', "$dir/$n.pl" or die; print $fh "use strict; use warnings;\nreturn {\n$body\n};\n"; close $fh }

mig('2026_01_01_000001_create_users_table', <<'M');
up => sub { my ($s) = @_; $s->create('users', sub { my $t = shift;
  $t->id; $t->string('name'); $t->string('email')->unique; $t->string('password')->nullable;
  $t->integer('age')->nullable; $t->boolean('is_admin')->default(0); $t->json('settings')->nullable; $t->timestamps; }) },
down => sub { $_[0]->drop_if_exists('users') },
M
mig('2026_01_01_000002_create_posts_table', <<'M');
up => sub { my ($s) = @_; $s->create('posts', sub { my $t = shift;
  $t->id; $t->foreign_id('user_id')->constrained->cascade_on_delete; $t->string('title');
  $t->integer('votes')->default(0); $t->boolean('published')->default(0); $t->timestamps; $t->soft_deletes; }) },
down => sub { $_[0]->drop_if_exists('posts') },
M
mig('2026_01_01_000003_create_comments_table', <<'M');
up => sub { my ($s) = @_; $s->create('comments', sub { my $t = shift;
  $t->id; $t->foreign_id('post_id')->constrained->cascade_on_delete; $t->text('body'); $t->timestamps; }) },
down => sub { $_[0]->drop_if_exists('comments') },
M
mig('2026_01_01_000004_create_roles_table', <<'M');
up => sub { my ($s) = @_;
  $s->create('roles', sub { my $t = shift; $t->id; $t->string('name'); $t->timestamps; });
  $s->create('role_user', sub { my $t = shift;
    $t->foreign_id('user_id')->constrained->cascade_on_delete;
    $t->foreign_id('role_id')->constrained->cascade_on_delete;
    $t->string('note')->nullable;
    $t->primary(['user_id', 'role_id']); }) },
down => sub { $_[0]->drop_if_exists('role_user'); $_[0]->drop_if_exists('roles') },
M
mig('2026_01_01_000005_create_profiles_table', <<'M');
up => sub { my ($s) = @_; $s->create('profiles', sub { my $t = shift;
  $t->id; $t->foreign_id('user_id')->constrained->cascade_on_delete; $t->timestamps; }) },
down => sub { $_[0]->drop_if_exists('profiles') },
M
mig('2026_01_01_000006_add_bio_to_profiles_table', <<'M');
up   => sub { $_[0]->table('profiles', sub { $_[0]->text('bio')->nullable }) },
down => sub { $_[0]->table('profiles', sub { $_[0]->drop_column('bio') }) },
M

# ---------------------------------------------------------------- the suite
my %targets = (sqlite => { driver => 'sqlite', database => ':memory:' });
$targets{pg}    = { url => $ENV{YGGDRASIL_TEST_PG} }    if $ENV{YGGDRASIL_TEST_PG};
$targets{mysql} = { url => $ENV{YGGDRASIL_TEST_MYSQL} } if $ENV{YGGDRASIL_TEST_MYSQL};

for my $name (sort keys %targets) {
  subtest "driver: $name" => sub { run_suite($name, $targets{$name}) };
}
done_testing;

sub run_suite {
  my ($drv, $cfg) = @_;
  my $yggdrasil = Yggdrasil->init(
    connections => { default => $cfg, other => { driver => 'sqlite', database => ':memory:' } },
    default => 'default', model_namespaces => ['TestApp::Model'],
    migration_paths => { default => [$dir], other => [$dir] },
  );
  my $db = $yggdrasil->connection;
  $db->schema->drop_all_tables if $ENV{"YGGDRASIL_TEST_\U$drv"} || $drv eq 'sqlite';
  my $m = $yggdrasil->migrator;

  # ---- migrations
  is scalar @{$m->pending}, 6, 'six pending migrations';
  my $ran = $m->run;
  is scalar @$ran, 6, 'ran six';
  is $ran->[0]{batch}, 1, 'single batch';
  ok $db->schema->has_table($_), "table $_ exists" for qw(users posts comments roles role_user profiles migrations);
  ok $db->schema->has_column('profiles', 'bio'), 'alter added column';
  is scalar @{$m->run}, 0, 'nothing to re-run';
  is_deeply [map { $_->{ran} } @{$m->status}], [(1) x 6], 'status all ran';

  $m->rollback(step => 1);
  ok !$db->schema->has_column('profiles', 'bio'), 'step rollback dropped the column (down)';
  is scalar @{$m->pending}, 1, 'one pending after rollback';
  $m->run;
  my $pre = $db->pretend(sub { $m->schema->create('zzz', sub { $_[0]->id; $_[0]->string('a') }) });
  like $pre->[0]{query}, qr/create table .zzz./, 'pretend captures SQL';
  ok !$db->schema->has_table('zzz'), '...without executing it';

  $m->reset;
  ok !$db->schema->has_table('users'), 'reset rolled everything back';
  $m->run;
  my $made = $m->make('add_slug_to_posts_table');
  ok -f $made, 'make() writes a stub'; like do { local (@ARGV, $/) = $made; <> }, qr/schema->table\('posts'/, 'alter stub';
  unlink $made;

  # ---- CRUD, mass assignment, casts, accessors, hooks
  my $u = TestApp::Model::User->create({ id => 999, name => 'alice', email => 'ALICE@Example.com', age => 30, is_admin => 1, settings => { tags => [1, 2] }, password => 'secret' });
  isnt $u->id, 999, 'primary key is guarded';
  ok $u->in_storage, 'in storage';
  is $u->email, 'alice@example.com', 'mutator';
  is $u->name, 'Alice', 'accessor';
  is_deeply $u->hook_log, ['saving', 'created'], 'hooks via Moo modifiers';
  my $f = TestApp::Model::User->find($u->id);
  ok $f->is_admin, 'bool cast'; is_deeply $f->settings, { tags => [1, 2] }, 'json cast round trip';
  is $f->age, 30, 'int cast';
  ok defined $f->created_at, 'timestamps set';
  my $h = $f->to_hash;
  ok !exists $h->{password}, 'hidden'; is $h->{shout}, 'ALICE!', 'appends';
  $f->age(31); ok $f->is_dirty('age'), 'dirty'; is_deeply [keys %{$f->get_dirty}], ['age'];
  $f->save; ok !$f->is_dirty, 'clean after save';
  is(TestApp::Model::User->find($u->id)->age, 31, 'update persisted');
  $f->update({ name => 'alicia' }); is(TestApp::Model::User->find($u->id)->name, 'Alicia', 'update()');
  my $json = JSON::PP->new->canonical->convert_blessed->encode($f); like $json, qr/"email":"alice\@example.com"/, 'TO_JSON';

  my $bob = TestApp::Model::User->create({ name => 'bob', email => 'bob@x.io', age => 17 });
  my $carl = TestApp::Model::User->create({ name => 'carl', email => 'carl@x.io', age => 45 });
  is(TestApp::Model::User->count, 3, 'count');
  is(TestApp::Model::User->adults->count, 2, 'local scope (static)');
  is(TestApp::Model::User->where(name => 'bob')->adults->count, 0, 'local scope (chained)');
  is_deeply [map { $_->attributes->{name} } @{TestApp::Model::User->order_by('age', 'desc')->get}], [qw(carl alicia bob)], 'order_by';
  is_deeply [@{TestApp::Model::User->order_by('id')->pluck('name')}], [qw(alicia bob carl)], 'pluck';
  is(TestApp::Model::User->sum('age'), 93, 'sum'); is(TestApp::Model::User->max('age'), 45, 'max');
  is(TestApp::Model::User->where_in('name', [qw(bob carl)])->where('age', '>', 20)->first->attributes->{name}, 'carl', 'where_in + first');
  ok(TestApp::Model::User->where(name => 'bob')->exists, 'exists'); ok(!TestApp::Model::User->where(name => 'zed')->exists, 'not exists');
  my $pg = TestApp::Model::User->order_by('id')->paginate(2, 2);
  is $pg->total, 3, 'paginate total'; is scalar @{$pg->items}, 1, 'paginate page 2'; is $pg->last_page, 2, 'last page';
  my @seen; TestApp::Model::User->order_by('id')->chunk(2, sub { push @seen, scalar @{$_[0]}; 1 }); is_deeply \@seen, [2, 1], 'chunk';
  is(TestApp::Model::User->where(name => 'bob')->update({ age => 18 }), 1, 'query update returns rows');
  ok(TestApp::Model::User->find($bob->id)->updated_at, 'query update touches updated_at');

  eval { TestApp::Model::User->find_or_fail(424242) };
  ok ref $@ && $@->is_not_found, 'find_or_fail throws not-found exception';
  eval { $db->table('users')->insert({ name => 'dup', email => 'bob@x.io' }) };
  ok ref $@ && $@->type eq 'query' && $@->sql =~ /insert into/, 'query errors carry SQL';

  my $fc = TestApp::Model::User->first_or_create({ email => 'dora@x.io' }, { name => 'dora' });
  ok $fc->in_storage; is(TestApp::Model::User->first_or_create({ email => 'dora@x.io' })->id, $fc->id, 'first_or_create is idempotent');
  my $uc = TestApp::Model::User->update_or_create({ email => 'dora@x.io' }, { age => 50 }); is $uc->id, $fc->id; is(TestApp::Model::User->find($fc->id)->age, 50, 'update_or_create');
  is(TestApp::Model::User->destroy($fc->id), 1, 'destroy');

  # ---- relations
  my $p1 = $u->posts->create({ title => 'First', votes => 1 });
  my $p2 = $u->posts->create({ title => 'Second', votes => 5, published => 1 });
  $bob->posts->create({ title => 'Bobs' });
  is $p1->attributes->{user_id}, $u->id, 'has_many create sets fk';
  is $u->posts->count, 2, 'relation is a query'; is $u->posts->where('votes', '>', 2)->get->first->attributes->{title}, 'Second', 'relation chaining';
  $p1->comments->create({ body => 'c1' }); $p1->comments->create({ body => 'c2' }); $p2->comments->create({ body => 'c3' });
  is scalar @{$u->related('posts')}, 2, 'lazy related()';
  is $p1->related('user')->id, $u->id, 'belongs_to';
  $u->profile->create({ bio => 'hi' }); is $u->related('profile')->attributes->{bio}, 'hi', 'has_one';

  my $log = $db->enable_query_log->query_log;
  my $users = TestApp::Model::User->include('posts.comments', 'profile')->order_by('id')->get;
  is scalar(@$log), 4, 'eager loading = 1 query per relation level (users, posts, comments, profiles)' or diag explain $log;
  is scalar @{$users->[0]->relations->{posts}}, 2, 'eager has_many';
  is scalar @{$users->[0]->relations->{posts}[0]->relations->{comments}}, 2, 'nested eager';
  is $users->[0]->relations->{profile}->attributes->{bio}, 'hi', 'eager has_one';
  ok !defined $users->[1]->relations->{profile}, 'eager has_one missing => undef';
  $db->disable_query_log;
  my $ps = TestApp::Model::Post->include('user')->get; is $ps->[0]->relations->{user}->id, $u->id, 'eager belongs_to';
  my $withcb = TestApp::Model::User->include(posts => sub { $_[0]->where('votes', '>', 2) })->where(id => $u->id)->first;
  is scalar @{$withcb->relations->{posts}}, 1, 'eager with constraint';
  ok ref $users->[0]->to_hash->{posts} eq 'ARRAY', 'to_hash includes loaded relations';

  my ($admin, $editor) = map { TestApp::Model::Role->create({ name => $_ }) } qw(admin editor);
  $u->roles->attach([$admin->id, $editor->id]);
  $bob->roles->attach($editor, { note => 'x' });
  is $u->roles->count, 2, 'belongs_to_many attach';
  my $roles = $u->roles->get; is_deeply [sort map { $_->attributes->{name} } @$roles], [qw(admin editor)], 'belongs_to_many get';
  is $roles->[0]->pivot->{user_id}, $u->id, 'pivot data'; 
  is $bob->roles->with_pivot('note')->get->first->pivot->{note}, 'x', 'with_pivot';
  my $eu = TestApp::Model::User->include('roles')->order_by('id')->get;
  is scalar @{$eu->[0]->relations->{roles}}, 2, 'eager belongs_to_many'; is scalar @{$eu->[1]->relations->{roles}}, 1;
  my $res = $u->roles->sync([$admin->id]); is_deeply $res->{detached}, [$editor->id], 'sync detaches'; is $u->roles->count, 1;
  $u->roles->sync([$admin->id, $editor->id]); is $u->roles->count, 2, 'sync attaches';
  $u->roles->detach($admin); is $u->roles->count, 1, 'detach';
  is scalar @{TestApp::Model::Role->find($editor->id)->users->get}, 2, 'inverse belongs_to_many';

  # ---- soft deletes
  is(TestApp::Model::Post->count, 3, 'posts counted');
  $p1->delete;
  ok $p1->trashed, 'trashed'; is(TestApp::Model::Post->count, 2, 'soft-deleted rows are hidden');
  is(TestApp::Model::Post->with_trashed->count, 3, 'with_trashed'); is(TestApp::Model::Post->only_trashed->count, 1, 'only_trashed');
  is $u->posts->count, 1, 'relations respect soft deletes';
  $p1->restore; ok !$p1->trashed; is(TestApp::Model::Post->count, 3, 'restored');
  TestApp::Model::Post->where(id => $p1->id)->delete; is(TestApp::Model::Post->count, 2, 'query delete is soft too');
  TestApp::Model::Post->with_trashed->where(id => $p1->id)->first->force_delete; is(TestApp::Model::Post->with_trashed->count, 2, 'force_delete');
  is(TestApp::Model::Comment->where(post_id => $p1->id)->count, 0, 'comments cascade with the force-deleted post');

  # ---- writes through the builder
  $db->table('users')->insert_or_ignore({ name => 'dup', email => 'bob@x.io' });
  is $db->table('users')->where(email => 'bob@x.io')->count, 1, 'insert_or_ignore';
  $db->table('roles')->upsert({ id => $admin->id, name => 'root' }, 'id', ['name']);
  is(TestApp::Model::Role->find($admin->id)->name, 'root', 'upsert update path');
  $db->table('posts')->where(id => $p2->id)->increment('votes', 10); is(TestApp::Model::Post->find($p2->id)->votes, 15, 'increment');
  $p2->decrement('votes', 5); is(TestApp::Model::Post->find($p2->id)->votes, 10, 'model decrement');

  # ---- transactions
  my $before = TestApp::Model::User->count;
  eval { $db->transaction(sub { TestApp::Model::User->create({ name => 'tx', email => 'tx@x.io' }); die "boom\n" }) };
  is $@, "boom\n", 'exception propagates'; is(TestApp::Model::User->count, $before, 'rolled back');
  $db->transaction(sub {
    TestApp::Model::User->create({ name => 'outer', email => 'o@x.io' });
    eval { $db->transaction(sub { TestApp::Model::User->create({ name => 'inner', email => 'i@x.io' }); die "inner\n" }) };
  });
  is(TestApp::Model::User->where(email => 'o@x.io')->count, 1, 'outer committed');
  is(TestApp::Model::User->where(email => 'i@x.io')->count, 0, 'nested savepoint rolled back');
  is(scalar($db->transaction(sub { 42 })), 42, 'transaction returns value');

  # ---- multiple connections
  my $other = $yggdrasil->migrator('other'); $other->run;
  TestApp::Model::User->on('other')->insert({ name => 'x', email => 'x@x.io' });
  is(TestApp::Model::User->on('other')->count, 1, 'second connection');
  is(TestApp::Model::User->where(email => 'x@x.io')->count, 0, 'default connection untouched');
  my $o = TestApp::Model::User->on('other')->first; $o->age(9); $o->save;
  is(TestApp::Model::User->on('other')->first->age, 9, 'instances remember their connection');

  # ---- raw escape hatches & safety
  is $db->select_all('select count(*) as n from users')->[0]{n}, TestApp::Model::User->count, 'raw select';
  my $weird = TestApp::Model::User->create({ name => q{Robert'); DROP TABLE users;--}, email => 'bobby@x.io' });
  is(TestApp::Model::User->find($weird->id)->attributes->{name}, q{Robert'); DROP TABLE users;--}, 'values are bound, not interpolated');

  $m->fresh; is(TestApp::Model::User->count, 0, 'fresh');
  $yggdrasil->disconnect_all;
}

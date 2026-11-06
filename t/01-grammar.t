use strict;
use warnings;
use Test::More;
use Mimir::Connection;
use Mimir::Schema::Blueprint;

my %c = map { $_ => Mimir::Connection->new(name => $_, config => { driver => $_, database => 'x' }) } qw(sqlite mysql pg);

sub sql_of { my ($drv, $cb) = @_; my $q = $cb->($c{$drv}->table('users')); my ($s, $b) = $q->compile; return ($s, $b) }

# --- basic select & quoting
{
  my ($s, $b) = sql_of(sqlite => sub { $_[0]->where(active => 1)->where('age', '>=', 18)->order_by('name')->limit(10)->offset(20) });
  is $s, 'select * from "users" where "active" = ? and "age" >= ? order by "name" asc limit 10 offset 20';
  is_deeply $b, [1, 18];
  ($s) = sql_of(mysql => sub { $_[0]->select('id', 'name as n')->where(id => 3) });
  is $s, 'select `id`, `name` as `n` from `users` where `id` = ?';
}

# --- where flavours
{
  my ($s, $b) = sql_of(pg => sub {
    $_[0]->where(a => 1)->or_where(b => undef)->where_in('c', [1, 2, 3])->where_not_null('d')
      ->where_between('e', [1, 5])->where(sub { $_[0]->where(x => 1)->or_where(y => 2) });
  });
  is $s, 'select * from "users" where "a" = ? or "b" is null and "c" in (?, ?, ?) and "d" is not null and "e" between ? and ? and ("x" = ? or "y" = ?)';
  is_deeply $b, [1, 1, 2, 3, 1, 5, 1, 2];

  ($s, $b) = sql_of(sqlite => sub { $_[0]->where_in('id', []) });
  like $s, qr/where 0 = 1/;
  ($s, $b) = sql_of(sqlite => sub { $_[0]->where({ a => 1, b => [1, 2] }) });
  is $s, 'select * from "users" where "a" = ? and "b" in (?, ?)';
  ($s, $b) = sql_of(sqlite => sub { $_[0]->where_in('id', sub { $_[0]->from('posts')->select('user_id')->where(published => 1) }) });
  is $s, 'select * from "users" where "id" in (select "user_id" from "posts" where "published" = ?)';
  ($s, $b) = sql_of(sqlite => sub { $_[0]->where_exists(sub { $_[0]->from('posts')->where_column('posts.user_id', 'users.id') }) });
  is $s, 'select * from "users" where exists (select * from "posts" where "posts"."user_id" = "users"."id")';
  ($s, $b) = sql_of(sqlite => sub { $_[0]->where_raw('lower(name) = ?', 'bob') });
  is $s, 'select * from "users" where lower(name) = ?';
  is_deeply $b, ['bob'];
}

# --- operators are whitelisted, identifiers are escaped
{
  eval { $c{sqlite}->table('users')->where('a', '= 1; drop table users; --', 1) };
  like $@, qr/invalid operator/;
  my ($s) = sql_of(sqlite => sub { $_[0]->where('we"ird', 1) });
  is $s, 'select * from "users" where "we""ird" = ?';
  eval { $c{sqlite}->table('users')->order_by('id', 'desc; drop') };
  like $@, qr/invalid order direction/;
  eval { $c{sqlite}->table('users')->limit('1; drop') };
  like $@, qr/non-negative integer/;
}

# --- joins, grouping
{
  my ($s) = sql_of(sqlite => sub {
    $_[0]->select('users.name', \'count(posts.id) as n')->left_join('posts', 'posts.user_id', 'users.id')
      ->group_by('users.id')->having('n', '>', 2)->order_by_raw('n desc');
  });
  is $s, 'select "users"."name", count(posts.id) as n from "users" left join "posts" on "posts"."user_id" = "users"."id" group by "users"."id" having "n" > ? order by n desc';
}

# --- driver differences
{
  my ($s) = sql_of(sqlite => sub { $_[0]->offset(5) });  like $s, qr/limit -1 offset 5$/;
  ($s) = sql_of(mysql  => sub { $_[0]->offset(5) });     like $s, qr/limit 18446744073709551615 offset 5$/;
  ($s) = sql_of(pg     => sub { $_[0]->offset(5) });     like $s, qr/ offset 5$/; unlike $s, qr/limit/;
  ($s) = sql_of(pg     => sub { $_[0]->lock_for_update });  like $s, qr/for update$/;
  ($s) = sql_of(mysql  => sub { $_[0]->shared_lock });      like $s, qr/lock in share mode$/;
  ($s) = sql_of(sqlite => sub { $_[0]->lock_for_update });  unlike $s, qr/for update/;
  ($s) = sql_of(mysql  => sub { $_[0]->where('name', 'ilike', 'a%') }); like $s, qr/`name` like \?/;
  ($s) = sql_of(pg     => sub { $_[0]->where('name', 'ilike', 'a%') }); like $s, qr/"name" ilike \?/;
}

# --- writes
{
  my $q = $c{pg}->table('users');
  my $g = $c{pg}->grammar;
  my @b;
  is $g->compile_insert($q, [{ name => 'a', age => 1 }, { name => 'b', age => 2 }], \@b), 'insert into "users" ("age", "name") values (?, ?), (?, ?)';
  is_deeply \@b, [1, 'a', 2, 'b'];
  @b = ();
  is $g->compile_insert_get_id($q, { name => 'a' }, \@b, 'id'), 'insert into "users" ("name") values (?) returning "id"';
  @b = ();
  is $g->compile_upsert($q, [{ email => 'e', name => 'n' }], \@b, ['email'], ['name']),
    'insert into "users" ("email", "name") values (?, ?) on conflict ("email") do update set "name" = excluded."name"';
  @b = ();
  is $c{mysql}->grammar->compile_upsert($c{mysql}->table('users'), [{ email => 'e', name => 'n' }], \@b, ['email'], ['name']),
    'insert into `users` (`email`, `name`) values (?, ?) on duplicate key update `name` = values(`name`)';
  @b = ();
  is $c{sqlite}->grammar->compile_insert($c{sqlite}->table('users'), [{ a => 1 }], \@b, ignore => 1), 'insert or ignore into "users" ("a") values (?)';
  @b = ();
  is $c{pg}->grammar->compile_insert($q, [{ a => 1 }], \@b, ignore => 1), 'insert into "users" ("a") values (?) on conflict do nothing';
  @b = ();
  is $c{mysql}->grammar->compile_insert($c{mysql}->table('t'), [{}], \@b), 'insert into `t` () values ()';

  @b = ();
  my $u = $c{sqlite}->table('users')->where(id => 4)->where_null('x');
  is $c{sqlite}->grammar->compile_update($u, { name => 'z', votes => \'"votes" + 1' }, \@b),
    'update "users" set "name" = ?, "votes" = "votes" + 1 where "id" = ? and "x" is null';
  is_deeply \@b, ['z', 4];
  @b = ();
  is $c{sqlite}->grammar->compile_delete($u, \@b), 'delete from "users" where "id" = ? and "x" is null';
}

# --- schema grammar
sub ddl {
  my ($drv, $cb, $create) = @_;
  my $bp = Mimir::Schema::Blueprint->new(table => 'posts', create => $create // 1);
  $cb->($bp);
  return $c{$drv}->grammar->compile_blueprint($bp);
}
my $create = sub {
  my $t = shift;
  $t->id;
  $t->string('title', 100);
  $t->text('body')->nullable;
  $t->boolean('published')->default(0);
  $t->decimal('price', 8, 2)->default(9.5);
  $t->foreign_id('user_id')->constrained->cascade_on_delete;
  $t->string('slug')->unique;
  $t->index(['published', 'title']);
  $t->timestamps;
};
is_deeply [ddl(sqlite => $create)], [
  'create table "posts" ("id" integer not null primary key autoincrement, "title" varchar(100) not null, "body" text null, "published" tinyint(1) not null default 0, "price" numeric(8, 2) not null default 9.5, "user_id" bigint not null, "slug" varchar(255) not null, "created_at" datetime null, "updated_at" datetime null, constraint "posts_user_id_foreign" foreign key ("user_id") references "users" ("id") on delete cascade)',
  'create index "posts_published_title_index" on "posts" ("published", "title")',
  'create unique index "posts_slug_unique" on "posts" ("slug")',
];
is_deeply [ddl(pg => $create)], [
  'create table "posts" ("id" bigserial not null primary key, "title" varchar(100) not null, "body" text null, "published" boolean not null default false, "price" numeric(8, 2) not null default 9.5, "user_id" bigint not null, "slug" varchar(255) not null, "created_at" timestamp(0) without time zone null, "updated_at" timestamp(0) without time zone null, constraint "posts_user_id_foreign" foreign key ("user_id") references "users" ("id") on delete cascade)',
  'create index "posts_published_title_index" on "posts" ("published", "title")',
  'create unique index "posts_slug_unique" on "posts" ("slug")',
];
is_deeply [ddl(mysql => $create)], [
  'create table `posts` (`id` bigint unsigned not null auto_increment primary key, `title` varchar(100) not null, `body` text null, `published` tinyint(1) not null default 0, `price` decimal(8, 2) not null default 9.5, `user_id` bigint unsigned not null, `slug` varchar(255) not null, `created_at` timestamp null default null, `updated_at` timestamp null default null, constraint `posts_user_id_foreign` foreign key (`user_id`) references `users` (`id`) on delete cascade) default character set utf8mb4 collate utf8mb4_unicode_ci engine = InnoDB',
  'create index `posts_published_title_index` on `posts` (`published`, `title`)',
  'create unique index `posts_slug_unique` on `posts` (`slug`)',
];

my $alter = sub {
  my $t = shift;
  $t->string('subtitle')->nullable->after('title');
  $t->drop_column('body');
  $t->rename_column('title', 'headline');
  $t->drop_index(['published', 'title']);
};
is_deeply [ddl(mysql => $alter, 0)], [
  'alter table `posts` add column `subtitle` varchar(255) null after `title`',
  'alter table `posts` drop column `body`',
  'alter table `posts` rename column `title` to `headline`',
  'drop index `posts_published_title_index` on `posts`',
];
is_deeply [ddl(pg => $alter, 0)], [
  'alter table "posts" add column "subtitle" varchar(255) null',
  'alter table "posts" drop column "body"',
  'alter table "posts" rename column "title" to "headline"',
  'drop index "posts_published_title_index"',
];
eval { ddl(sqlite => sub { $_[0]->foreign('user_id')->references('id')->on('users') }, 0) };
like $@, qr/SQLite cannot add a foreign key/;

is_deeply [ddl(pg => sub { $_[0]->enum('status', ['a', "b'c"])->default('a') })],
  ['create table "posts" ("status" varchar(255) check ("status" in (\'a\', \'b\'\'c\')) not null default \'a\')'];

done_testing;

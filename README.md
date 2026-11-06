# Mojolicious::Plugin::Yggdrasil

An **Eloquent-style ORM** for Mojolicious: query builder, Moo-based models, relations,
eager loading, soft deletes, schema builder and file-based migrations — on
**SQLite, MySQL/MariaDB and PostgreSQL**, with **several named connections** at once.

```perl
plugin Yggdrasil => {
  default     => 'main',
  connections => {
    main    => { driver => 'sqlite', database => 'db/app.db' },
    reports => { url    => 'postgresql://user:pass@localhost/reports' },
    legacy  => { driver => 'mysql', host => 'db1', database => 'old', username => 'u', password => 'p' },
  },
  models     => ['MyApp::Model'],
  migrations => 'migrations',
};

my $user = $c->model('User')->where(email => $email)->first;
my $top  = $c->model('Post')->include('user', 'comments')->latest->limit(10)->get;
$c->model('User')->on('reports')->count;          # another connection
$c->table('audit_log')->insert({ ... });           # plain query builder, no model
```

## Install

```
cpanm --installdeps .      # Moo, Mojolicious >= 9, DBI
cpanm DBD::SQLite DBD::Pg DBD::mysql   # whichever databases you use
prove -l t/
```

## Configuration

| key | meaning |
|---|---|
| `connections` | `{ name => \%config }`. Omit it and put `driver`/`database`/… at top level for a single connection called `default`. |
| `default` | name of the default connection (default: `default`, else the first by name) |
| `models` | namespaces searched by `$c->model('User')` / relations (default: `<AppClass>::Model`) |
| `migrations` | directory (relative to `$app->home`), or `{ conn => dir }`. Default `migrations` for the default connection and `migrations/<name>` for others |
| `migrate` | `1` = run pending migrations of the default connection on startup |
| `log` | `1` = log every query (SQL, bindings, ms) with `$app->log->debug` |

Connection options: `driver` (`sqlite`, `mysql`, `pg`; aliases `postgres`, `postgresql`, `mariadb`),
`database`, `host`, `port`, `username`, `password`, `socket`, **or** `url`
(`sqlite:db/app.db`, `sqlite::memory:`, `mysql://u:p@host/db`, `postgresql://u:p@host:5432/db`), or a raw `dsn`.
Extras: `options` (extra DBI attributes), `on_connect => sub ($dbh) {}`, `timezone`, `search_path` (pg),
`charset`/`collation`/`engine` (mysql DDL), `pragmas => { journal_mode => 'WAL' }` (sqlite; `foreign_keys=ON` and
`busy_timeout` are on by default), `ping_interval` (seconds, default 60).

Helpers: `$c->yggdrasil` (manager), `$c->db($name?)` (connection), `$c->model('User')` (class name), `$c->table('users', $conn?)` (query builder).
Outside a Mojolicious app: `Yggdrasil->init(connections => {...}, model_namespaces => [...])`.

## Models

```perl
package MyApp::Model::User;
use Moo;
extends 'Yggdrasil::Model';
with 'Yggdrasil::Role::SoftDeletes';                 # optional

sub fillable { [qw(name email password settings)] }  # mass assignment (default: everything except the primary key)
sub hidden   { ['password'] }                    # left out of to_hash / JSON
sub casts    { { is_admin => 'bool', settings => 'json', age => 'int' } }
sub appends  { ['display_name'] }                # computed attributes included in to_hash

sub get_display_name_attribute { $_[0]->attributes->{name} . ' <' . $_[0]->attributes->{email} . '>' }
sub set_password_attribute     { my ($self, $v) = @_; return crypt_it($v) }   # returns the value to store

sub posts   { $_[0]->has_many('Post') }
sub profile { $_[0]->has_one('Profile') }
sub roles   { $_[0]->belongs_to_many('Role') }

sub scope_active { my ($class, $q) = @_; $q->where(active => 1) }   # User->active->get

# plain Moo: attributes, roles, method modifiers are all available
has token => (is => 'lazy');                     # NOT a column, just an object attribute
before saving => sub { ... };
after  created => sub { ... };
1;
```

Conventions (all overridable with a class method of the same name): `table` (`User` → `users`), `primary_key` (`id`),
`incrementing`, `timestamps` (`created_at`/`updated_at`, filled in UTC), `connection_name`, `per_page`.
Hooks: `saving saved creating created updating updated deleting deleted` — override them, wrap them with Moo
modifiers, or `die` to abort.

Column access: `$u->name`, `$u->name('x')` (chainable), `$u->get_attribute('name')`, `$u->set_attribute(...)`,
`$u->attributes`. **Reserved names:** a column whose name matches a real method on the model is shadowed by that method, so
`$u->meta` returns Moo's meta-class object, not your column. Affected names: Moo's `meta`, `new`, `has`, `with`, `extends`,
`before`, `after`, `around`, `does`, plus model methods such as `table`, `count`, `first`, `save`, `delete`, `update`,
`query`, `fill`, `attributes`, `original`, `relations`, `pivot`, `using`. Read/write those columns with
`$u->get_attribute('meta')` / `$u->set_attribute(meta => ...)` — or pick another column name.

```perl
my $u = User->create({ name => 'Ann', email => 'ann@x.io' });    # or User->new({...})->save
$u->update({ name => 'Anne' });   $u->age(31)->save;   $u->is_dirty;   $u->get_dirty;
$u->increment('logins');          $u->refresh;         $u->fresh;      $u->replicate;
$u->delete;                       User->destroy(1, 2, 3);
User->find(1);  User->find([1,2]);  User->find_or_fail(1);  User->first_or_create({ email => $e }, { name => $n });
User->update_or_create({ email => $e }, { name => $n });
User->on('reports')->where(...)->get;                            # pick a connection
```

`find_or_fail` / `first_or_fail` throw a `Yggdrasil::Exception` with `->is_not_found`; SQL errors throw one with `->sql`
and `->bindings`.

**Soft deletes** (`with 'Yggdrasil::Role::SoftDeletes'`, needs `$t->soft_deletes` in the migration): `delete` sets
`deleted_at`, queries and relations hide trashed rows; `Post->with_trashed`, `Post->only_trashed`,
`$p->trashed`, `$p->restore`, `$p->force_delete`.

> **Why `include` and not `with`?** Moo exports its own `with` into every class that does `use Moo`,
> which would shadow an inherited `User->with(...)`. Use `User->include('posts')`. On a query or relation object
> `->with('posts')` works as an alias.

## Query builder

Everything works on a model class (`User->where(...)`) or on a table (`$c->table('users')->where(...)`).
Methods are snake_case and chainable.

| | |
|---|---|
| select | `select(@cols)`, `add_select`, `select_raw($sql, @bind)`, `distinct` |
| where | `where($col, $val)`, `where($col, $op, $val)`, `where({ a => 1, b => [1,2] })`, `where(sub { $_[0]->where(..)->or_where(..) })`, `or_where`, `where_in`, `where_not_in` (arrayref, subquery or coderef), `where_null`, `where_not_null`, `where_between`, `where_column`, `where_exists`, `where_raw($sql, @bind)` and the `or_` variants. `undef` → `IS NULL`; an arrayref → `IN` |
| join | `join($table, $a, $b)`, `join($table, $a, $op, $b)`, `left_join`, `right_join`, `cross_join`, or `join($t, sub { $_[0]->on(..)->or_on(..) })` |
| group/order | `group_by`, `having`, `having_raw`, `order_by($col, 'desc')`, `order_by_raw`, `latest`, `oldest`, `reorder` |
| limit | `limit`/`take`, `offset`/`skip`, `for_page($page, $per)`, `lock_for_update`, `shared_lock` |
| misc | `when($cond, $cb)`, `tap($cb)`, `clone`, `to_sql`, `bindings`, `include(...)` / `with(...)` |
| read | `get`, `first`, `find`, `find_or_fail`, `first_or_fail`, `value($col)`, `pluck($col, $key?)`, `exists`, `count`, `sum`, `avg`, `min`, `max`, `paginate($per, $page)`, `chunk($size, $cb)`, `each($cb)` |
| write | `insert(\%row \| \@rows)`, `insert_get_id`, `insert_or_ignore`, `upsert(\@rows, $unique_cols, $update_cols)`, `update(\%set)`, `increment`, `decrement`, `delete`, `truncate` |

Raw SQL is always possible: a scalar ref is a raw expression (`$q->update({ votes => \'votes + 1' })`,
`$q->select(\'count(*) as n')`), `\[ 'sql ?', $bind ]` is a raw expression with bindings, and
`$c->db->select_all($sql, @bind)` / `->statement($sql, @bind)` run plain SQL.
Values are **always** bound; identifiers are quoted/escaped; operators and sort directions are whitelisted.

`paginate` returns an object with `items`, `total`, `per_page`, `current_page`, `last_page`, `from`, `to`,
`has_more_pages` and `TO_JSON` (so `render(json => $page)` just works).

## Relations

```perl
sub posts    { $_[0]->has_many('Post') }               # posts.user_id
sub profile  { $_[0]->has_one('Profile') }
sub user     { $_[0]->belongs_to('User') }             # this.user_id
sub roles    { $_[0]->belongs_to_many('Role') }        # pivot role_user(user_id, role_id)
# explicit keys:  has_many($class, $foreign_key, $local_key), belongs_to($class, $fk, $owner_key),
#                 belongs_to_many($class, $pivot_table, $fpk, $rpk, $parent_key, $related_key)
```

```perl
$user->posts->where('votes', '>', 5)->order_by('id')->get;   # a relation is a constrained query
$user->posts->create({ title => 'Hi' });                      # foreign key filled in
$user->related('posts');                                      # lazy-load once, cached
$user->load('posts.comments');                                # eager-load on an instance

User->include('posts.comments', 'profile')->get;              # eager loading: one query per relation
User->include(posts => sub { $_[0]->where(published => 1) })->get;

$user->roles->attach([1, 2]);   $user->roles->attach($role, { note => 'x' });
$user->roles->detach($role);    $user->roles->sync([1, 3]);   $user->roles->with_pivot('note')->get;
$role->pivot->{note};                                         # pivot columns on loaded models
$post->user->associate($u);                                   # belongs_to
```

## Migrations

`./myapp.pl yggdrasil make:migration create_posts_table` writes `migrations/2026_11_06_101500_create_posts_table.pl`:

```perl
use strict; use warnings;
return {
  up => sub {
    my ($schema, $db) = @_;
    $schema->create('posts', sub {
      my $t = shift;
      $t->id;
      $t->foreign_id('user_id')->constrained->cascade_on_delete;
      $t->string('title', 150);
      $t->text('body')->nullable;
      $t->boolean('published')->default(0);
      $t->decimal('price', 8, 2)->default(0);
      $t->json('settings')->nullable;
      $t->string('slug')->unique;
      $t->index(['published', 'created_at']);
      $t->timestamps;
      $t->soft_deletes;
    });
  },
  down => sub { $_[0]->drop_if_exists('posts') },
};
```

```
./myapp.pl yggdrasil migrate [--pretend] [--step]     # run pending (one batch; --step: a batch per migration)
./myapp.pl yggdrasil rollback [--step N]              # undo last batch (or last N migrations)
./myapp.pl yggdrasil reset | refresh | fresh | status
./myapp.pl yggdrasil make:migration NAME [--create TABLE | --table TABLE]
./myapp.pl yggdrasil make:model Post [-m] [-f FIELDS]      # model (+ migration), e.g.
#   -f "title:string,body:text?,user_id:foreign,slug:string!,views:integer=0"
#   ?=nullable  !=unique  =X default  foreign=foreign_id()->constrained  decimal(8,2)=arguments
./myapp.pl yggdrasil migrate -c reports               # any command accepts --connection
```
`create_x_table` / `add_y_to_x_table` names generate the right stub. Each connection has its own migration directory
and its own `migrations` table. Migrations run inside a transaction on SQLite/PostgreSQL (MySQL DDL cannot be rolled back).

**Schema builder** — `$schema->create($t, $cb)`, `->table($t, $cb)` (alter), `drop`, `drop_if_exists`, `rename`,
`has_table`, `has_column`, `get_columns`, `drop_all_tables`, `raw`.

Columns: `id`, `big_increments`, `increments`, `string($n, $len=255)`, `char`, `text`, `medium_text`, `long_text`,
`integer`, `big_integer`, `small_integer`, `tiny_integer`, `unsigned_integer`, `boolean`, `float`, `double`,
`decimal($n, $p, $s)`, `date`, `datetime`, `timestamp`, `time`, `json` (jsonb on PostgreSQL, text on SQLite),
`uuid`, `binary`, `enum($n, \@values)`, `foreign_id`, `timestamps`, `soft_deletes`.
Modifiers: `nullable`, `default($v)` (`\'CURRENT_TIMESTAMP'` for expressions), `use_current`, `unsigned`, `unique`,
`index`, `primary`, `comment` (MySQL), `after` (MySQL), `constrained($table?, $col?)`, `on_delete`, `on_update`,
`cascade_on_delete`, `null_on_delete`.
Table-level: `index(\@cols)`, `unique(\@cols)`, `primary(\@cols)`, `foreign($col)->references('id')->on('t')->on_delete('cascade')`,
`drop_column`, `rename_column`, `drop_index`, `drop_unique`, `drop_foreign`, `drop_timestamps`, `drop_soft_deletes`.

## Transactions

```perl
$c->db->transaction(sub {            # rolls back and rethrows on die; nested calls use SAVEPOINTs
  my $order = Order->create({ ... });
  $order->items->create({ ... });
});
```

## Notes & limitations

* DBI is **blocking** (as are Mojo::Pg/Mojo::SQLite without their async APIs); use `hypnotoad`/`prefork` for concurrency.
  Connections are lazy and **fork-safe** (a child never reuses its parent's socket) and re-ping after idle periods.
* SQLite: `alter table` cannot add foreign keys/primary keys (declare them in `create`); `drop/rename column` need SQLite ≥ 3.35 / 3.25.
  MySQL `rename column` needs 8.0+. MySQL `ilike` is mapped to `like`.
* The model layer finds the active `Yggdrasil` object through a process-wide singleton (`Yggdrasil->instance`, set by the plugin).
  One Mojolicious app per process is the supported setup.
* Query-builder `update`/`delete` bypass model hooks and mutators (they still apply casts, `updated_at` and soft deletes).

## Testing

```
prove -l t/                                   # SQL generation + SQLite end-to-end (+ plugin tests if Mojolicious is installed)
YGGDRASIL_TEST_PG='postgresql://u:p@localhost/yggdrasil_test' YGGDRASIL_TEST_MYSQL='mysql://u:p@localhost/yggdrasil_test' prove -l t/10-orm.t
```
**The PG/MySQL runs drop every table in the target database — use empty, dedicated test databases.**

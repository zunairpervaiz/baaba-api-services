import 'package:baaba_api_handler/baaba_api_handler.dart';
import 'package:flutter/material.dart';

import 'config/api_setup.dart';
import 'config/endpoints.dart';
import 'partner_repository.dart';

/// A runnable tour of the package against a public test API.
///
/// Shows the pieces you would actually wire up in an app: two clients
/// configured once in `config/api_setup.dart` (the second pinned to its own
/// CA and proxied on staging), endpoints and settings generated from `env/`
/// by baaba_api_generator (`dart run build_runner build`), typed responses,
/// failure handling, and the global loading indicator.
void main() {
  configureApi(observer: ConsoleObserver());

  // No name: shared by both clients, so a request on each still opens one
  // indicator and closes it once.
  ApiServices.configureLoader(
    onShow: () => _loading.value = true,
    onHide: () => _loading.value = false,
  );

  runApp(const ExampleApp());
}

final _loading = ValueNotifier<bool>(false);

/// Logs every outcome in one place, instead of at each call site.
class ConsoleObserver extends ApiObserver {
  @override
  void onFailure(Failure failure, RequestOptions? options) {
    debugPrint(
      '[api] ${options?.method} ${options?.path} → ${failure.message}',
    );
  }
}

class Post {
  final int id;
  final String title;
  final String body;

  const Post({required this.id, required this.title, required this.body});

  factory Post.fromJson(Map<String, dynamic> json) => Post(
    id: json['id'] as int,
    title: json['title'] as String,
    body: json['body'] as String,
  );
}

class PostRepository {
  /// Every request this repository makes carries this tag, so a screen can
  /// cancel its own work without touching anyone else's.
  static const tag = 'posts';

  final ApiServices _api;

  PostRepository([ApiServices? api]) : _api = api ?? ApiServices.instance();

  /// Typed, and cancellable by tag, in one call.
  Future<Either<Failure, List<Post>>> latest() {
    return _api.getAs<List<Post>>(
      endpoint: '/posts',
      parser: listParser(Post.fromJson),
      params: {'_limit': 20},
      tag: tag,
    );
  }

  /// An endpoint generated from `env/endpoints.env`: `posts/{postId}/comments`
  /// becomes `Endpoints.postComments(postId)`.
  Future<Either<Failure, int>> commentCount(int postId) {
    return _api.getAs<int>(
      endpoint: Endpoints.postComments(postId),
      parser: (data) => (data as List).length,
      tag: tag,
    );
  }

  Future<Either<Failure, Post>> create(String title, String body) {
    return _api.postAs<Post>(
      endpoint: '/posts',
      parser: (data) => Post.fromJson(data as Map<String, dynamic>),
      data: {'title': title, 'body': body, 'userId': 1},
      tag: tag,
    );
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'baaba_api_handler',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const PostsPage(),
    );
  }
}

class PostsPage extends StatefulWidget {
  const PostsPage({super.key});

  @override
  State<PostsPage> createState() => _PostsPageState();
}

class _PostsPageState extends State<PostsPage> {
  final _repository = PostRepository();
  final _partner = PartnerRepository();

  List<Post> _posts = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Abort what is still in flight for this screen — and only that. Without
    // a tag, cancelRequest() aborts every request in the app, including those
    // of screens still on the stack.
    ApiServices.instance().cancelRequest(
      tag: PostRepository.tag,
      cancellationReason: 'Screen closed',
    );
    super.dispose();
  }

  Future<void> _load() async {
    final result = await _repository.latest();

    if (!mounted) return;
    result.fold(
      (failure) => setState(() => _error = failure.message),
      (posts) => setState(() {
        _posts = posts;
        _error = null;
      }),
    );
  }

  Future<void> _create() async {
    final result = await _repository.create('Hello', 'From the example app');

    if (!mounted) return;
    result.fold(
      (failure) {
        // Field-level errors when the server sends them, one message otherwise.
        final fields = failure.validationErrors;
        final message = fields != null
            ? fields.entries.map((e) => '${e.key}: ${e.value.first}').join('\n')
            : failure.message;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      },
      (post) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Created post ${post.id}'))),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showComments(Post post) async {
    final result = await _repository.commentCount(post.id);
    if (!mounted) return;
    result.fold(
      (failure) => _toast(failure.message),
      (count) => _toast('Post ${post.id} has $count comments'),
    );
  }

  /// The partner host is a placeholder, so this always fails — the point is
  /// what the failure says.
  Future<void> _checkPartner() async {
    final result = await _partner.latestStatement('ACC-001');
    if (!mounted) return;
    result.fold(
      (failure) => _toast(PartnerRepository.describe(failure)),
      _toast,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Posts'),
        actions: [
          IconButton(
            tooltip: 'Partner statement',
            icon: const Icon(Icons.account_balance),
            onPressed: _checkPartner,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        child: const Icon(Icons.add),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _loading,
        builder: (context, loading, child) {
          return Stack(
            children: [
              child!,
              if (loading)
                const ColoredBox(
                  color: Color(0x33000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
        child: RefreshIndicator(
          onRefresh: _load,
          child: _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : ListView.separated(
                  // Pull-to-refresh needs something to overscroll, even when
                  // the list is empty.
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: _posts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final post = _posts[index];
                    return ListTile(
                      title: Text(post.title, maxLines: 1),
                      subtitle: Text(post.body, maxLines: 2),
                      onTap: () => _showComments(post),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Scrollable, so the RefreshIndicator around it still responds to a pull.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

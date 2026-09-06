import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ResumeMatcherApp());
}

class ResumeMatcherApp extends StatelessWidget {
  const ResumeMatcherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Resume Shortlister',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ShortlistDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MetricScore {
  final String name;
  final double weight;
  final double score;
  final String reasoning;

  MetricScore({
    required this.name,
    required this.weight,
    required this.score,
    required this.reasoning,
  });

  factory MetricScore.fromJson(Map<String, dynamic> json) {
    return MetricScore(
      name: json['name']?.toString() ?? '',
      weight: (json['weight'] as num?)?.toDouble() ?? 0.0,
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      reasoning: json['reasoning']?.toString() ?? '',
    );
  }
}

class CandidateEvaluation {
  final String candidateName;
  final double compositeScore;
  final List<MetricScore> metrics;
  final List<String> strengths;
  final List<String> redFlags;

  CandidateEvaluation({
    required this.candidateName,
    required this.compositeScore,
    required this.metrics,
    required this.strengths,
    required this.redFlags,
  });

  factory CandidateEvaluation.fromJson(Map<String, dynamic> json) {
    return CandidateEvaluation(
      candidateName: json['candidate_name']?.toString() ?? 'Candidate',
      compositeScore: (json['composite_score'] as num?)?.toDouble() ?? 0.0,
      metrics: (json['metrics'] as List? ?? [])
          .map((m) => MetricScore.fromJson(m as Map<String, dynamic>))
          .toList(),
      strengths: List<String>.from(json['strengths'] ?? []),
      redFlags: List<String>.from(json['red_flags'] ?? []),
    );
  }
}

class ShortlistDashboard extends StatefulWidget {
  const ShortlistDashboard({super.key});

  @override
  State<ShortlistDashboard> createState() => _ShortlistDashboardState();
}

class _ShortlistDashboardState extends State<ShortlistDashboard> {
  PlatformFile? _jdFile;
  final List<PlatformFile> _resumeFiles = [];
  double _topN = 3;
  bool _isLoading = false;
  String? _errorMessage;
  List<CandidateEvaluation> _results = [];

  Future<void> _pickJdFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx'],
      withData: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _jdFile = result.files.first;
        _errorMessage = null;
      });
    }
  }

  void _removeJdFile() {
    setState(() {
      _jdFile = null;
    });
  }

  Future<void> _pickResumeFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx'],
      allowMultiple: true,
      withData: true,
    );
    if (result != null) {
      setState(() {
        _resumeFiles.addAll(result.files);
        if (_resumeFiles.isNotEmpty) {
          _topN = _topN.clamp(1.0, _resumeFiles.length.toDouble());
        }
        _errorMessage = null;
      });
    }
  }

  void _removeResume(int index) {
    setState(() {
      _resumeFiles.removeAt(index);
      final maxLimit = _resumeFiles.isEmpty ? 1.0 : _resumeFiles.length.toDouble();
      if (_topN > maxLimit) {
        _topN = maxLimit;
      }
    });
  }

  Future<void> _submitShortlist() async {
    if (_jdFile == null) {
      setState(() => _errorMessage = 'Upload a job description first.');
      return;
    }
    if (_resumeFiles.isEmpty) {
      setState(() => _errorMessage = 'Select at least one resume.');
      return;
    }

    final Uint8List? jdBytes = _jdFile!.bytes;
    if (jdBytes == null) {
      setState(() => _errorMessage = 'Could not read JD bytes.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('http://127.0.0.1:8000/shortlist');
      final request = http.MultipartRequest('POST', uri);

      request.fields['top_n'] = _topN.round().toString();

      request.files.add(
        http.MultipartFile.fromBytes(
          'jd_file',
          jdBytes,
          filename: _jdFile!.name,
        ),
      );

      for (final file in _resumeFiles) {
        if (file.bytes != null) {
          request.files.add(
            http.MultipartFile.fromBytes(
              'resume_files',
              file.bytes!,
              filename: file.name,
            ),
          );
        }
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final dynamicList = decoded['shortlisted'] as List? ?? [];
        final parsed = dynamicList
            .map((e) => CandidateEvaluation.fromJson(e as Map<String, dynamic>))
            .toList();

        setState(() {
          _results = parsed;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Server error (${response.statusCode}): ${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Connection error: $e';
      });
    }
  }

  Color _scoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TalentFilter Engine', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 1,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900;
          return Row(
            children: [
              SizedBox(
                width: isWide ? 420 : constraints.maxWidth,
                child: _buildSidebar(),
              ),
              if (isWide) const VerticalDivider(width: 1),
              if (isWide) Expanded(child: _buildResultsPanel()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSidebar() {
    final hasResumes = _resumeFiles.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              border: Border.all(color: Colors.red.shade200),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade800),
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Text('Job Description', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_jdFile == null)
          OutlinedButton.icon(
            onPressed: _pickJdFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('Select JD (PDF/DOCX)'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          )
        else
          ListTile(
            tileColor: Colors.blue.shade50,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            leading: const Icon(Icons.description, color: Colors.blue),
            title: Text(_jdFile!.name, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.close, color: Colors.grey),
              onPressed: _removeJdFile,
            ),
          ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Resumes (${_resumeFiles.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            TextButton.icon(
              onPressed: _pickResumeFiles,
              icon: const Icon(Icons.add),
              label: const Text('Add Files'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 180,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _resumeFiles.isEmpty
              ? const Center(child: Text('No resumes uploaded yet', style: TextStyle(color: Colors.grey)))
              : ListView.separated(
                  itemCount: _resumeFiles.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final file = _resumeFiles[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.picture_as_pdf, size: 20),
                      title: Text(file.name, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () => _removeResume(index),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Candidates to Shortlist', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Top ${_topN.round()}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ],
        ),
        Slider(
          value: _topN,
          min: 1,
          max: hasResumes ? _resumeFiles.length.toDouble() : 10,
          divisions: hasResumes && _resumeFiles.length > 1 ? _resumeFiles.length - 1 : 1,
          label: _topN.round().toString(),
          onChanged: hasResumes ? (val) => setState(() => _topN = val) : null,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _isLoading ? null : _submitShortlist,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Process & Rank Resumes'),
        ),
      ],
    );
  }

  Widget _buildResultsPanel() {
    if (_results.isEmpty) {
      return const Center(
        child: Text('Run the shortlisting pipeline to view ranked scores.', style: TextStyle(color: Colors.grey)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Colors.grey.shade200),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExpansionTile(
            shape: Border.all(color: Colors.transparent),
            leading: CircleAvatar(
              backgroundColor: _scoreColor(item.compositeScore),
              child: Text(
                '#${index + 1}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            title: Text(item.candidateName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            subtitle: Text('Score: ${item.compositeScore.toStringAsFixed(1)} / 100'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Strengths:', style: TextStyle(fontWeight: FontWeight.bold)),
                    ...item.strengths.map((s) => Text('� $s')),
                    const SizedBox(height: 8),
                    const Text('Risks / Gaps:', style: TextStyle(fontWeight: FontWeight.bold)),
                    ...item.redFlags.map((f) => Text('� $f')),
                    const SizedBox(height: 16),
                    const Text('Metric Breakdown:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...item.metrics.map(
                      (m) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(flex: 3, child: Text(m.name, style: const TextStyle(fontSize: 13))),
                            Expanded(
                              flex: 5,
                              child: LinearProgressIndicator(
                                value: m.score / 100,
                                backgroundColor: Colors.grey.shade200,
                                color: _scoreColor(m.score),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('${m.score.toInt()}%', style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

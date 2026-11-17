import 'package:flutter/material.dart';

void main() {
  runApp(const MiAppObra());
}

class MiAppObra extends StatelessWidget {
  const MiAppObra({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'App de Obra',
      home: const PantallaPrincipal(),
    );
  }
}

class PantallaPrincipal extends StatelessWidget {
  const PantallaPrincipal({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi App de Obra'),
      ),
      body: const Center(
        child: Text(
          '¡Mi aplicación personalizada!',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}

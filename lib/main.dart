import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(const IMaxTciApp());
}

class IMaxTciApp extends StatelessWidget {
  const IMaxTciApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'i-MAX 3 TCI Controller',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF101010),
      ),
      home: const MainDashboardScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainDashboardScreen extends StatefulWidget {
  const MainDashboardScreen({super.key});

  @override
  State<MainDashboardScreen> createState() => _MainDashboardScreenState();
}

class _MainDashboardScreenState extends State<MainDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // --- USB Serial State ---
  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  bool isConnected = false;
  String connectionStatus = "Disconnected";

  // --- Live Data Stream ---
  double batteryVoltage = 0.0;
  int engineTemp = 0;
  double afrValue = 0.0;
  int currentRpm = 0;

  // --- System Configuration ---
  String bikeModel = "SATRIA-FU";
  String tciType = "i-MAX3 TCI SUPER PRO";
  String tciVersion = "VER 1.0.05 - 2026";
  bool fanActive = true;
  double overheatTemp = 95.0;
  double quickshifterTime = 60.0;
  bool tss0Active = true;
  bool tss1Active = false;
  double revLimit = 13000;

  // Selected Node untuk Geser Grafik
  int? selectedPointIndex;

  // --- Data Master Mapping (Dapat Diinput Presisi Tanpa Batas) ---
  List> mapData = [
    {'rpm': 500, 'deg': 10.0, 'dwell': 4.5},
    {'rpm': 1000, 'deg': 15.0, 'dwell': 4.5},
    {'rpm': 2000, 'deg': 18.25, 'dwell': 4.0},
    {'rpm': 3000, 'deg': 24.0, 'dwell': 3.5},
    {'rpm': 4000, 'deg': 30.5, 'dwell': 3.0},
    {'rpm': 5000, 'deg': 34.0, 'dwell': 2.8},
    {'rpm': 6000, 'deg': 36.75, 'dwell': 2.5},
    {'rpm': 7000, 'deg': 39.0, 'dwell': 2.5}, // CDI Tuning Max Degree
    {'rpm': 8000, 'deg': 35.0, 'dwell': 2.2},
    {'rpm': 9000, 'deg': 31.2, 'dwell': 2.0},
    {'rpm': 10000, 'deg': 28.0, 'dwell': 2.0},
    {'rpm': 11000, 'deg': 25.5, 'dwell': 1.8},
    {'rpm': 12000, 'deg': 24.0, 'dwell': 1.8},
    {'rpm': 13000, 'deg': 24.0, 'dwell': 1.8},
    {'rpm': 14000, 'deg': 20.0, 'dwell': 1.5},
    {'rpm': 15000, 'deg': 15.0, 'dwell': 1.2},
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initUsbListener();
  }

  @override
  void dispose() {
    _disconnectUsb();
    _tabController.dispose();
    super.dispose();
  }

  // --- Koneksi USB OTG to TTL ---
  void _initUsbListener() {
    UsbSerial.usbEventStream?.listen((UsbEvent event) {
      if (event.event == UsbEvent.ACTION_USB_DEVICE_ATTACHED) {
        _connectUsb();
      } else if (event.event == UsbEvent.ACTION_USB_DEVICE_DETACHED) {
        _disconnectUsb();
      }
    });
    _connectUsb();
  }

  Future<void> _connectUsb() async {
    List<UsbDevice> devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      setState(() {
        isConnected = false;
        connectionStatus = "Soket USB OTG / TTL Belum Dicolok";
      });
      return;
    }

    try {
      _port = await devices.first.create();
      bool openResult = await _port!.open();
      if (!openResult) {
        setState(() {
          connectionStatus = "Gagal Buka Port Serial";
        });
        return;
      }

      await _port!.setDtr(true);
      await _port!.setRts(true);
      await _port!.setPortParameters(
        38400, // Baudrate Komunikasi i-MAX 3
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _subscription = _port!.inputStream!.listen((Uint8List data) {
        _parseCdiStream(data);
      });

      setState(() {
        isConnected = true;
        connectionStatus = "TERHUBUNG (KABEL OTG TTL)";
      });
    } catch (e) {
      setState(() {
        connectionStatus = "Error: $e";
      });
    }
  }

  void _disconnectUsb() {
    _subscription?.cancel();
    _port?.close();
    _port = null;
    setState(() {
      isConnected = false;
      connectionStatus = "Terputus";
    });
  }

  void _parseCdiStream(Uint8List data) {
    if (data.length >= 6) {
      setState(() {
        currentRpm = (data[0] << 8) | data[1];
        batteryVoltage = data[2] / 10.0;
        engineTemp = data[3];
        afrValue = data[4] / 10.0;
      });
    }
  }

  Future<void> _uploadMapToCdi() async {
    if (!isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Sambungkan Kabel USB OTG TTL ke Soket CDI Terlebih Dahulu!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    List<int> packet = [0xAA, 0x55]; // Header
    for (var row in mapData) {
      packet.add(((row['deg'] as double) * 10).toInt()); // Kirim desimal * 10
      packet.add(((row['dwell'] as double) * 10).toInt());
    }
    packet.add(revLimit ~/ 100);
    packet.add(0xFF); // Tail

    await _port!.write(Uint8List.fromList(packet));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚡ Peta Pengapian Presisi Berhasil Ditulis ke EEPROM TCI!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.flash_on, color: Colors.amberAccent),
            const SizedBox(width: 8),
            Text(
              'i-MAX 3 PROGRAMMABLE TCI',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.blue.shade200,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isConnected ? Colors.green : Colors.red),
            ),
            child: Row(
              children: [
                CircleAvatar(radius: 4, backgroundColor: isConnected ? Colors.green : Colors.red),
                const SizedBox(width: 6),
                Text(connectionStatus, style: TextStyle(fontSize: 11, color: isConnected ? Colors.greenAccent : Colors.redAccent)),
              ],
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.show_chart), text: "Interactive Curve"),
            Tab(icon: Icon(Icons.table_chart), text: "Precision Remap"),
            Tab(icon: Icon(Icons.settings_input_component), text: "ECU Parameters"),
          ],
        ),
      ),
      body: Row(
        children: [
          // Sidebar Kiri
          _buildLeftSidebar(),

          // Menu Utama (Sesuai Tab)
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildInteractiveChartTab(),
                _buildPrecisionTableTab(),
                _buildEcuParametersTab(),
              ],
            ),
          ),

          // Sidebar Kanan - Live Display
          _buildLiveMonitorPanel(),
        ],
      ),
    );
  }

  Widget _buildLeftSidebar() {
    return Container(
      width: 230,
      color: const Color(0xFF181818),
      padding: const EdgeInsets.all(10.0),
      child: ListView(
        children: [
          const Text("CONFIG PROFILE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent, fontSize: 11)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: bikeModel,
            decoration: const InputDecoration(labelText: 'Bike Model', border: OutlineInputBorder(), isDense: true),
            items: ['SATRIA-FU', 'JUPITER Z', 'CB150R', 'SONIC 150', 'MIO BOREUP']
                .map((val) => DropdownMenuItem(value: val, child: Text(val, style: const TextStyle(fontSize: 11))))
                .toList(),
            onChanged: (val) => setState(() => bikeModel = val!),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: tciType,
            decoration: const InputDecoration(labelText: 'TCI Type', border: OutlineInputBorder(), isDense: true),
            items: ['i-MAX3 TCI SUPER PRO', 'i-MAX3 STANDARD', 'i-MAX3 DUAL BAND']
                .map((val) => DropdownMenuItem(value: val, child: Text(val, style: const TextStyle(fontSize: 10))))
                .toList(),
            onChanged: (val) => setState(() => tciType = val!),
          ),
          const SizedBox(height: 15),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
            icon: const Icon(Icons.cloud_upload, size: 16),
            label: const Text('Burn / Send Map'),
            onPressed: _uploadMapToCdi,
          ),
        ],
      ),
    );
  }

  // === FITUR: GRAFIK BISA DIGESER PAKAI JARI / TOUCH INTERAKSI ===
  Widget _buildInteractiveChartTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Kurva Ignition Degree (Sentuh & Geser Titik Grafik)", style: TextStyle(fontWeight: FontWeight.bold)),
              if (selectedPointIndex != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.3), borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    "Terpilih: ${mapData[selectedPointIndex!]['rpm']} RPM -> ${mapData[selectedPointIndex!]['deg']}°",
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchCallback: (FlTouchEvent event, LineTouchResponse? touchResponse) {
                    if (touchResponse != null && touchResponse.lineBarSpots != null && touchResponse.lineBarSpots!.isNotEmpty) {
                      setState(() {
                        selectedPointIndex = touchResponse.lineBarSpots!.first.spotIndex;
                      });
                    }
                  },
                  handleBuiltInTouches: true,
                ),
                gridData: FlGridData(
                  show: true,
                  getDrawingHorizontalLine: (val) => FlLine(color: Colors.white12, strokeWidth: 1),
                  getDrawingVerticalLine: (val) => FlLine(color: Colors.white12, strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 2000,
                      getTitlesWidget: (val, meta) => Text('${val.toInt()}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 10,
                      getTitlesWidget: (val, meta) => Text('${val.toInt()}°', style: const TextStyle(fontSize: 10, color: Colors.redAccent)),
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
                lineBarsData: [
                  LineChartBarData(
                    spots: mapData.map((e) => FlSpot((e['rpm'] as int).toDouble(), (e['deg'] as num).toDouble())).toList(),
                    isCurved: true,
                    color: Colors.redAccent,
                    barWidth: 3,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) {
                        bool isSelected = index == selectedPointIndex;
                        return FlDotCirclePainter(
                          radius: isSelected ? 8 : 4,
                          color: isSelected ? Colors.amber : Colors.redAccent,
                          strokeWidth: isSelected ? 3 : 1,
                          strokeColor: Colors.white,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (selectedPointIndex != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Text("Ubah Derajat (${mapData[selectedPointIndex!]['rpm']} RPM): "),
                IconButton(
                  icon: const Icon(Icons.remove_circle, color: Colors.red),
                  onPressed: () {
                    setState(() {
                      mapData[selectedPointIndex!]['deg'] = (mapData[selectedPointIndex!]['deg'] - 0.25).clamp(0.0, 60.0);
                    });
                  },
                ),
                Text(
                  "${mapData[selectedPointIndex!]['deg']}°",
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.green),
                  onPressed: () {
                    setState(() {
                      mapData[selectedPointIndex!]['deg'] = (mapData[selectedPointIndex!]['deg'] + 0.25).clamp(0.0, 60.0);
                    });
                  },
                ),
                Slider(
                  value: (mapData[selectedPointIndex!]['deg'] as num).toDouble(),
                  min: 0,
                  max: 60,
                  divisions: 240, // Presisi 0.25 Derajat Per Geser
                  onChanged: (val) {
                    setState(() {
                      mapData[selectedPointIndex!]['deg'] = double.parse(val.toStringAsFixed(2));
                    });
                  },
                ),
              ],
            )
          ]
        ],
      ),
    );
  }

  // === FITUR: TABEL MANUAL INPUT ANGKANYA SANGAT DETAIL (0 - TANPA BATAS) ===
  Widget _buildPrecisionTableTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Manual Input Table (Dukungan Desimal Tak Terbatas)", style: TextStyle(fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text("Tambah Titik RPM"),
                onPressed: () {
                  _showAddRpmDialog();
                },
              )
            ],
          ),
          const SizedBox(height: 10),
          Card(
            color: const Color(0xFF1C1C1C),
            child: DataTable(
              columnSpacing: 25,
              columns: const [
                DataColumn(label: Text('RPM')),
                DataColumn(label: Text('Ignition Degree (°)')),
                DataColumn(label: Text('Dwell Time (ms)')),
                DataColumn(label: Text('Hapus')),
              ],
              rows: mapData.asMap().entries.map((entry) {
                int idx = entry.key;
                var row = entry.value;
                return DataRow(cells: [
                  DataCell(Text('${row['rpm']}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent))),
                  DataCell(
                    SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue: row['deg'].toString(),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                        onChanged: (val) {
                          double? parsed = double.tryParse(val);
                          if (parsed != null) {
                            row['deg'] = parsed;
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue: row['dwell'].toString(),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                        onChanged: (val) {
                          double? parsed = double.tryParse(val);
                          if (parsed != null) {
                            row['dwell'] = parsed;
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
                  DataCell(
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      onPressed: () {
                        setState(() {
                          mapData.removeAt(idx);
                        });
                      },
                    ),
                  ),
                ]);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddRpmDialog() {
    TextEditingController rpmController = TextEditingController();
    TextEditingController degController = TextEditingController(text: "20.0");
    TextEditingController dwellController = TextEditingController(text: "2.5");

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Tambah Titik Mapping Baru"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: rpmController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Nisbahkan RPM (misal: 6500)")),
            TextField(controller: degController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: "Derajat (misal: 35.5)")),
            TextField(controller: dwellController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: "Dwell Time ms (misal: 2.25)")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Batal")),
          ElevatedButton(
            onPressed: () {
              int? r = int.tryParse(rpmController.text);
              double? d = double.tryParse(degController.text);
              double? dw = double.tryParse(dwellController.text);
              if (r != null && d != null && dw != null) {
                setState(() {
                  mapData.add({'rpm': r, 'deg': d, 'dwell': dw});
                  mapData.sort((a, b) => (a['rpm'] as int).compareTo(b['rpm'] as int));
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text("Simpan"),
          )
        ],
      ),
    );
  }

  Widget _buildEcuParametersTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          color: const Color(0xFF1E1E1E),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Limiter & Heat Security", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                const SizedBox(height: 10),
                Text("Rev Limiter: ${revLimit.toInt()} RPM"),
                Slider(
                  value: revLimit,
                  min: 5000,
                  max: 20000, // Batas RPM Hingga 20.000 RPM
                  divisions: 150,
                  onChanged: (val) => setState(() => revLimit = val),
                ),
                SwitchListTile(
                  title: const Text("Fan Active Output"),
                  value: fanActive,
                  onChanged: (val) => setState(() => fanActive = val),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveMonitorPanel() {
    return Container(
      width: 200,
      color: const Color(0xFF141414),
      padding: const EdgeInsets.all(10.0),
      child: Column(
        children: [
          const Text("LIVE DATA MODE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 12)),
          const Divider(height: 15),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.redAccent)),
            child: Column(
              children: [
                const Text("TACHOMETER", style: TextStyle(fontSize: 9, color: Colors.grey)),
                Text("$currentRpm", style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.redAccent)),
                const Text("RPM", style: TextStyle(fontSize: 9, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _buildLiveTile("Voltage", "${batteryVoltage.toStringAsFixed(2)} V", Icons.battery_charging_full, Colors.greenAccent),
          const SizedBox(height: 6),
          _buildLiveTile("Engine Temp", "$engineTemp °C", Icons.thermostat, Colors.orangeAccent),
          const SizedBox(height: 6),
          _buildLiveTile("AFR Ratio", "${afrValue.toStringAsFixed(1)}", Icons.speed, Colors.blueAccent),
        ],
      ),
    );
  }

  Widget _buildLiveTile(String label, String val, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey)),
              Text(val, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}

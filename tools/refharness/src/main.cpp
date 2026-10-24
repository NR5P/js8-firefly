// Reference harness: exposes the original JS8Call protocol code over a simple
// line-oriented stdin/stdout interface so the Swift port can be cross-checked.
//
// Commands (fields separated by TAB):
//   ENC    type  submode  frame12                  -> 79 tone digits
//   FRAMES submode mycall mygrid selected forceId forceData text
//                                                  -> frame:bits:message ... (TAB separated)
//   DT     frame bits submode                      -> frameType TAB message
//   DECODE path submode nfqso                      -> one line per decode, then END
//   GEN    path submode freq type frame snr seed   -> writes int16 12 kHz raw file

#include <QCoreApplication>
#include <QString>
#include <QStringList>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <random>
#include <string>
#include <vector>

#include "JS8.hpp"
#include "commons.h"
#include "decodedtext.h"
#include "varicode.h"

std::size_t js8ref_decode(int submodeBit, JS8::Event::Emitter emit);

namespace {
int nsps(int submode) {
  switch (submode) {
  case 0: return JS8A_SYMBOL_SAMPLES;
  case 1: return JS8B_SYMBOL_SAMPLES;
  case 2: return JS8C_SYMBOL_SAMPLES;
  case 4: return JS8E_SYMBOL_SAMPLES;
  case 8: return JS8I_SYMBOL_SAMPLES;
  }
  return 0;
}
int periodSeconds(int submode) {
  switch (submode) {
  case 0: return 15; case 1: return 10; case 2: return 6; case 4: return 30; case 8: return 4;
  }
  return 0;
}
int startDelayMS(int submode) {
  switch (submode) {
  case 0: return 500; case 1: return 200; case 2: return 100; case 4: return 500; case 8: return 100;
  }
  return 0;
}
JS8::Costas::Type costasType(int submode) {
  return submode == 0 ? JS8::Costas::Type::ORIGINAL : JS8::Costas::Type::MODIFIED;
}
std::string esc(std::string const &in) {
  std::string out;
  for (char c : in) {
    if (c == '\\') out += "\\\\";
    else if (c == '\n') out += "\\n";
    else if (c == '\t') out += "\\t";
    else if (c == '\r') out += "\\r";
    else out.push_back(c);
  }
  return out;
}
std::string esc(QString const &in) { return esc(in.toStdString()); }
std::vector<std::string> split(std::string const &s) {
  std::vector<std::string> out;
  std::string cur;
  for (char ch : s) {
    if (ch == '\t') { out.push_back(cur); cur.clear(); }
    else cur.push_back(ch);
  }
  out.push_back(cur);
  return out;
}
} // namespace

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  std::string line;
  std::cout.setf(std::ios::unitbuf);
  while (std::getline(std::cin, line)) {
    auto f = split(line);
    if (f.empty()) continue;
    auto const &cmd = f[0];
    if (cmd == "ENC" && f.size() >= 4) {
      int type = std::stoi(f[1]);
      int submode = std::stoi(f[2]);
      std::array<int, 79> tones{};
      try {
        JS8::encode(type, JS8::Costas::array(costasType(submode)), f[3].c_str(), tones.data());
        for (int t : tones) std::cout << t;
        std::cout << "\n";
      } catch (...) {
        std::cout << "ERR\n";
      }
    } else if (cmd == "FRAMES" && f.size() >= 8) {
      int submode = std::stoi(f[1]);
      auto frames = Varicode::buildMessageFrames(
          QString::fromStdString(f[2]), QString::fromStdString(f[3]),
          QString::fromStdString(f[4]), QString::fromStdString(f[7]),
          f[5] == "1", f[6] == "1", submode, nullptr);
      QStringList out;
      for (auto const &fr : frames) {
        DecodedText dt(fr.first, fr.second, submode);
        out << QString::fromStdString(esc(QString("%1:%2:%3").arg(fr.first).arg(fr.second).arg(dt.message())));
      }
      std::cout << out.join("\t").toStdString() << "\n";
    } else if (cmd == "DT" && f.size() >= 4) {
      DecodedText dt(QString::fromStdString(f[1]), std::stoi(f[2]), std::stoi(f[3]));
      std::cout << int(dt.frameType()) << "\t" << esc(dt.message()) << "\t"
                << esc(dt.directedMessage().join("|")) << "\t"
                << esc(dt.compoundCall()) << "\t" << esc(dt.extra())
                << "\t" << (dt.isHeartbeat() ? 1 : 0) << (dt.isAlt() ? 1 : 0) << "\n";
    } else if (cmd == "DECODE" && f.size() >= 4) {
      int submode = std::stoi(f[2]);
      std::ifstream in(f[1], std::ios::binary);
      std::vector<int16_t> samples((std::istreambuf_iterator<char>(in)), {});
      // istreambuf gives chars; reinterpret properly
      in.clear(); in.seekg(0, std::ios::end);
      auto bytes = in.tellg(); in.seekg(0);
      samples.assign(bytes / 2, 0);
      in.read(reinterpret_cast<char *>(samples.data()), bytes);
      std::fill(std::begin(dec_data.d2), std::end(dec_data.d2), 0);
      int n = std::min<int>(samples.size(), JS8_RX_SAMPLE_SIZE);
      std::copy_n(samples.begin(), n, dec_data.d2);
      auto &p = dec_data.params;
      p.nutc = 0; p.nfqso = std::stoi(f[3]); p.nfa = 0; p.nfb = 5000; p.syncStats = false;
      int const sz = std::min(n, periodSeconds(submode) * 12000);
      p.kposA = p.kposB = p.kposC = p.kposE = p.kposI = 0;
      p.kszA = p.kszB = p.kszC = p.kszE = p.kszI = sz;
      js8ref_decode(submode, [](JS8::Event::Variant const &ev) {
        if (auto d = std::get_if<JS8::Event::Decoded>(&ev)) {
          std::cout << d->data << "\t" << d->type << "\t" << d->snr << "\t" << d->xdt
                    << "\t" << d->frequency << "\t" << d->quality << "\n";
        }
      });
      std::cout << "END\n";
    } else if (cmd == "GEN" && f.size() >= 8) {
      int submode = std::stoi(f[2]);
      double freq = std::stod(f[3]);
      int type = std::stoi(f[4]);
      double snr = std::stod(f[6]);
      std::mt19937 rng(std::stoi(f[7]));
      std::normal_distribution<double> gauss(0.0, 1.0);
      std::array<int, 79> tones{};
      JS8::encode(type, JS8::Costas::array(costasType(submode)), f[5].c_str(), tones.data());
      int const ns = nsps(submode);
      int const total = periodSeconds(submode) * 12000;
      int const start = startDelayMS(submode) * 12;
      std::vector<double> sig(total, 0.0);
      double phi = 0;
      double const spacing = 12000.0 / ns;
      for (int k = 0; k < 79; ++k) {
        double dphi = 2 * M_PI * (freq + tones[k] * spacing) / 12000.0;
        for (int i = 0; i < ns; ++i) {
          int idx = start + k * ns + i;
          if (idx < total) sig[idx] = std::sin(phi);
          phi = std::fmod(phi + dphi, 2 * M_PI);
        }
      }
      // SNR in 2500 Hz bandwidth: noise sigma relative to unit-amplitude sine
      double const sigPower = 0.5;
      double const noisePower2500 = sigPower / std::pow(10.0, snr / 10.0);
      double const sigma = std::sqrt(noisePower2500 * 6000.0 / 2500.0);
      std::vector<int16_t> out(total);
      double const scale = 1000.0;
      for (int i = 0; i < total; ++i) {
        double v = (sig[i] + (snr < 90 ? sigma * gauss(rng) : 0.0)) * scale;
        out[i] = static_cast<int16_t>(std::clamp(v, -32767.0, 32767.0));
      }
      std::ofstream o(f[1], std::ios::binary);
      o.write(reinterpret_cast<char const *>(out.data()), out.size() * 2);
      std::cout << "OK\n";
    } else {
      std::cout << "ERR\n";
    }
  }
  return 0;
}

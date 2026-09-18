// Minimal JSON/JS string emitters.
//
// Neutrino only ever *writes* JSON from C++ (event payloads, request headers);
// parsing happens on the Lua side. That keeps this to a couple of escapers and
// a tiny object builder, with no third-party dependency in the native layer.

#ifndef NEUTRINO_JSON_H
#define NEUTRINO_JSON_H

#include <string>
#include <vector>

namespace neutrino {

// Escapes |in| into a double-quoted JSON string, quotes included.
inline std::string JsonQuote(const std::string& in) {
  std::string out;
  out.reserve(in.size() + 2);
  out.push_back('"');
  for (unsigned char c : in) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b";  break;
      case '\f': out += "\\f";  break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (c < 0x20) {
          static const char* hex = "0123456789abcdef";
          out += "\\u00";
          out.push_back(hex[(c >> 4) & 0xF]);
          out.push_back(hex[c & 0xF]);
        } else {
          // Pass UTF-8 continuation bytes through untouched.
          out.push_back(static_cast<char>(c));
        }
    }
  }
  out.push_back('"');
  return out;
}

// Escapes |in| into a single-quoted JavaScript string literal, quotes included.
// Line separators must be escaped too: U+2028/U+2029 terminate a JS line.
inline std::string JsQuote(const std::string& in) {
  std::string out;
  out.reserve(in.size() + 2);
  out.push_back('\'');
  for (size_t i = 0; i < in.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(in[i]);
    switch (c) {
      case '\'': out += "\\'";  break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      case '<':  out += "\\x3C"; break;  // avoid closing an enclosing </script>
      default:
        if (c == 0xE2 && i + 2 < in.size() &&
            static_cast<unsigned char>(in[i + 1]) == 0x80 &&
            (static_cast<unsigned char>(in[i + 2]) == 0xA8 ||
             static_cast<unsigned char>(in[i + 2]) == 0xA9)) {
          out += (static_cast<unsigned char>(in[i + 2]) == 0xA8) ? "\\u2028"
                                                                 : "\\u2029";
          i += 2;
        } else if (c < 0x20) {
          static const char* hex = "0123456789abcdef";
          out += "\\x";
          out.push_back(hex[(c >> 4) & 0xF]);
          out.push_back(hex[c & 0xF]);
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  out.push_back('\'');
  return out;
}

// Builds a flat JSON object one key at a time. Values are emitted in insertion
// order, which keeps event payloads readable in logs.
class JsonObject {
 public:
  JsonObject& Str(const char* key, const std::string& value) {
    Comma();
    body_ += JsonQuote(key) + ":" + JsonQuote(value);
    return *this;
  }
  JsonObject& Int(const char* key, int64_t value) {
    Comma();
    body_ += JsonQuote(key) + ":" + std::to_string(value);
    return *this;
  }
  JsonObject& Num(const char* key, double value) {
    Comma();
    body_ += JsonQuote(key) + ":" + std::to_string(value);
    return *this;
  }
  JsonObject& Bool(const char* key, bool value) {
    Comma();
    body_ += JsonQuote(key) + ":" + (value ? "true" : "false");
    return *this;
  }
  // Inserts a already-encoded JSON fragment (object, array, number...).
  JsonObject& Raw(const char* key, const std::string& encoded) {
    Comma();
    body_ += JsonQuote(key) + ":" + encoded;
    return *this;
  }

  std::string Build() const { return "{" + body_ + "}"; }

 private:
  void Comma() {
    if (!body_.empty()) {
      body_.push_back(',');
    }
  }
  std::string body_;
};

}  // namespace neutrino

#endif  // NEUTRINO_JSON_H

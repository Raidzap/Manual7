#!/usr/bin/env python3
"""Gera um repositório APT plano (Packages + Release) para o Sileo/Zebra.

Uso: python3 tools/build_apt_repo.py SAIDA [pacote.deb ...]

Os pacotes informados são copiados para SAIDA/debs, e o índice cobre todos
os .deb dessa pasta, de qualquer projeto. Sem pacotes, só refaz o índice.
A pasta SAIDA pode ser publicada como está (GitHub Pages). O Sileo resolve
as dependências pelos repositórios do bootstrap (Procursus).
"""

import argparse
import bz2
import email.utils
import gzip
import html
import hashlib
import io
import lzma
import pathlib
import shutil
import sys
import tarfile

LABEL = "Raidzap"
DESCRIPTION = "Tweaks do Raidzap para iOS com jailbreak rootless."
DEFAULT_URL = "https://raidzap.github.io/repo/"
# (field in Packages, field in Release, hashlib name): dpkg spells "MD5sum".
HASHES = (("MD5sum", "MD5Sum", "md5"), ("SHA1", "SHA1", "sha1"), ("SHA256", "SHA256", "sha256"))


def ar_members(data):
    # Debian packages are plain "!<arch>" archives: 60-byte headers, 2-byte
    # aligned bodies.
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("não é um pacote .deb")
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        body = offset + 60
        yield name, data[body:body + size]
        offset = body + size + (size & 1)


def read_control(deb):
    for name, body in ar_members(deb):
        if not name.startswith("control.tar"):
            continue
        if name.endswith(".zst"):
            raise ValueError("control.tar.zst não suportado")
        with tarfile.open(fileobj=io.BytesIO(body)) as archive:
            for member in archive.getmembers():
                if member.name.lstrip("./") == "control":
                    return archive.extractfile(member).read().decode("utf-8")
    raise ValueError("pacote sem arquivo control")


def parse_control(text):
    fields, key = {}, None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t" and key:
            fields[key] += "\n" + line
            continue
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def version_key(version):
    # Enough for the X.Y.Z versions this project uses.
    return tuple(int(part) if part.isdigit() else 0 for part in version.replace("-", ".").split("."))


def package_stanza(control, filename, data):
    lines = [f"{key}: {value}" for key, value in control.items()]
    lines.append(f"Filename: {filename}")
    lines.append(f"Size: {len(data)}")
    for field, _, algorithm in HASHES:
        lines.append(f"{field}: {hashlib.new(algorithm, data).hexdigest()}")
    return "\n".join(lines) + "\n"


def release_file(indexes, date, architectures):
    lines = [
        f"Origin: {LABEL}",
        f"Label: {LABEL}",
        "Suite: stable",
        "Codename: ios",
        "Version: 1.0",
        # Sileo rejects a source whose Release lacks the device's dpkg architecture.
        f"Architectures: {' '.join(architectures)}",
        "Components: main",
        f"Description: {DESCRIPTION}",
        f"Date: {email.utils.format_datetime(date, usegmt=True)}",
    ]
    for _, field, algorithm in HASHES:
        lines.append(f"{field}:")
        for name, data in indexes.items():
            lines.append(f" {hashlib.new(algorithm, data).hexdigest()} {len(data)} {name}")
    return "\n".join(lines) + "\n"


def index_page(url, entries):
    rows = "".join(
        f"<li><b>{html.escape(control.get('Name', control['Package']))}</b> {html.escape(control['Version'])}"
        f" — {html.escape(control.get('Description', '').splitlines()[0] if control.get('Description') else '')}</li>"
        for control, _ in entries)
    source = html.escape(url)
    return (
        '<!doctype html><html lang="pt-BR"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>{LABEL} Repo</title>"
        '<body style="font-family:system-ui;max-width:36rem;margin:2rem auto;padding:0 1rem">'
        f"<h1>{LABEL}</h1><p>{html.escape(DESCRIPTION)}</p>"
        f'<p><a href="sileo://source/{source}">Adicionar ao Sileo</a> · '
        f'<a href="zbra://sources/add/{source}">Adicionar ao Zebra</a></p>'
        f"<p>Ou adicione a fonte manualmente: <code>{source}</code></p>"
        f"<ul>{rows}</ul></body></html>\n")


def build(output, debs, date=None, url=DEFAULT_URL):
    import datetime
    date = date or datetime.datetime.now(datetime.timezone.utc)
    output = pathlib.Path(output)
    pool = output / "debs"
    pool.mkdir(parents=True, exist_ok=True)
    for path in map(pathlib.Path, debs):
        if not path.is_file():
            raise ValueError(f"{path}: arquivo não encontrado")
        read_control(path.read_bytes())
        target = pool / path.name
        if not target.exists() or not target.samefile(path):
            shutil.copyfile(path, target)
    entries = []
    for path in sorted(pool.glob("*.deb")):
        data = path.read_bytes()
        control = parse_control(read_control(data))
        for required in ("Package", "Version", "Architecture"):
            if not control.get(required):
                raise ValueError(f"{path.name}: campo {required} ausente")
        entries.append((control["Package"], version_key(control["Version"]), control,
                        package_stanza(control, f"debs/{path.name}", data)))
    entries.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
    packages = "\n".join(stanza for *_, stanza in entries).encode("utf-8")
    indexes = {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
        "Packages.xz": lzma.compress(packages),
    }
    for name, data in indexes.items():
        (output / name).write_bytes(data)
    architectures = sorted({entry[2]["Architecture"] for entry in entries} - {"all"}) or ["iphoneos-arm64"]
    (output / "Release").write_text(release_file(indexes, date, architectures), encoding="utf-8")
    # GitHub Pages: serve every file as is, without a Jekyll build.
    (output / "index.html").write_text(index_page(url, [entry[2:] for entry in entries]), encoding="utf-8")
    (output / ".nojekyll").write_bytes(b"")
    return [stanza for *_, stanza in entries]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Gera o repositório APT para o Sileo/Zebra.")
    parser.add_argument("output", help="pasta do repositório")
    parser.add_argument("debs", nargs="*", help="pacotes .deb a adicionar")
    parser.add_argument("--url", default=DEFAULT_URL, help="endereço público do repositório")
    args = parser.parse_args(argv)
    try:
        stanzas = build(args.output, args.debs, url=args.url)
    except (OSError, ValueError) as error:
        print(f"Erro: {error}", file=sys.stderr)
        return 1
    print(f"{len(stanzas)} pacote(s) em {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# 📙 eijiro-search.el

このパッケージは[vui]をベースにGNU EmacsでEIJIRO(英辞郎)英和辞書の対話検索を提供します。

<a href="img/screenshot.png"><img src="img/screenshot.png" width="500"></a>

<div align="right">
<strong><a href="README.md">English README</a></strong>
</div>

## 要件

このパッケージを利用するには、以下が必要です。

 * **Emacs 29.1** 以降
 * [`vui.el`][vui]: Emacs向けの宣言的・コンポーネントベースなUIフレームワーク
 * [ripgrep] (`rg`) コマンド
 * UTF-8化された `EIJIRO144-10.TXT`（後述）

> [!NOTE]
> `vui.el` はMELPAで配布されているため、依存関係を解決するにはEmacsの設定で `package-archives` に[MELPA]を追加しておいてください。

## インストール

`eijiro-search` は `package-vc-install` (Emacs 29.1 以降で利用可能) でEmacsのコードを評価するとインストールできます。

```elisp
(package-vc-install
 '(eijiro-search :url "https://github.com/zonuexe/eijiro-search.el.git"
                 :main-file "eijiro-search.el"))
```

あなたの[Emacs初期化ファイル][Emacs init file]（`init.el`）で以下のように設定してください。

```elisp
(with-eval-after-load 'eijiro-search
  (setopt eijiro-search-dictionary-file
          (expand-file-name "~/path/to/dict-dir/EIJIRO144-10.TXT")))

;; もしuse-packageユーザーなら以下のように書くこともできます
(use-package eijiro-search
  :defer t
  :custom
  (eijiro-search-dictionary-file (expand-file-name "~/path/to/dict-dir/EIJIRO144-10.TXT")))
```

## データについて

このパッケージは[EDP]が販売する[英辞郎 Ver.144.10][EIJIRO-144]を対象にデータを検索します。

> [!WARNING]
> [株式会社アルク][ALC PRESS]が提供する[英辞郎 on the WEB]とは異なります。

購入したデータをダウンロードした後、文字コードを **Shift_JIS (CP932) / CR+LF** から **UTF-8 / LF** に変換します。

```sh
cd ~/path/to/dict-dir
EIJIROFILE=~/Downloads/EIJIRO144-10.TXT
if command -v nkf >/dev/null
then nkf -Lu -w80 "$EIJIROFILE"
else iconv -f CP932 -t UTF-8 "$EIJIROFILE" | tr -d '\r'
fi | tee EIJIRO144-10.TXT | sha256sum
```

正常に変換できれば、メッセージダイジェストは以下の通りになります。

 * `nkf -Luw80 ~/Downloads/EIJIRO144-10.TXT`
   * SHA-256: `7be6cbec1809012b8c247965d1ab71d3a57a12804a61e36496f55bd76e31af54`
 * `iconv -f UTF-8 -t UTF-8 | tr -d '\r'`
   * SHA-256: `be84db914dbad6812d05272280eca296d77ad0733e7d905ba39476b417e49f33`

> [!NOTE]
> `nkf`/`iconv`は`U+2014 EM DASH`と`U+2015 HORIZONTAL BAR`のマッピングが異なるため、同じダイジェストにはなりません。
>
> 差分は以下の2レコードであり、nkfとiconvのどちらを用いても実用的な問題はありません。
>
> ```diff
> --- nkf.txt
> +++ iconv.txt
> -■Angel of Death  {映画} : 要塞帝国—SS最終指令◆米1986年
> +■Angel of Death  {映画} : 要塞帝国―SS最終指令◆米1986年
> -■Japanese Society of Human-Environment System  {組織} : 人間—生活環境系学会◆【略】HES◆【URL】http://www.jhes-jp.com/jp/
> +■Japanese Society of Human-Environment System  {組織} : 人間―生活環境系学会◆【略】HES◆【URL】http://www.jhes-jp.com/jp/
> ```

## FAQ

### 最新の英辞郎に対応する予定はありますか？

テキスト形式のデータ販売は[英辞郎 Ver.144.10][EIJIRO-144]（2024年4月7日修正版）が最終版であることが宣言されています。

> ※ Ver.144.10 は最新版ではありませんが、2024年4月7日までに発見された間違いは修正されています。
> ※ Ver.145 以降のテキスト形式およびテキストに変換可能な形式（EPWINGなど）のデータが販売される予定はございません。（テキスト形式のデータを不正利用する人がいるので）

現在販売されている最新版の暗号化されたデジタルデータの目的外利用は禁止されているため、サポート予定はありません。

## Copyright

このパッケージは[GPLv3]で公開されています。詳細は[`LICENSE`](LICENSE)を参照してください。

> Copyright (C) 2026  USAMI Kenta
>
> This program is free software; you can redistribute it and/or modify
> it under the terms of the GNU General Public License as published by
> the Free Software Foundation, either version 3 of the License, or
> (at your option) any later version.
>
> This program is distributed in the hope that it will be useful,
> but WITHOUT ANY WARRANTY; without even the implied warranty of
> MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
> GNU General Public License for more details.
>
> You should have received a copy of the GNU General Public License
> along with this program.  If not, see <https://www.gnu.org/licenses/>.

### EIJIRO

辞書データは[英辞郎の利用規約][EIJIRO-terms]および、販売ページに記載されている「販売条件および使用条件」に従って利用してください。

***購入データを第三者に利用させることは禁止されています。***

`eijiro-search.el` は英辞郎データ作者(EDP)とは独立して開発されています。
利用方法についてデータ作者に問い合わせないでください。

[ALC PRESS]: https://www.alc.co.jp/
[EDP]: https://www.eijiro.jp/
[EIJIRO-144]: https://www.eijiro.jp/get-144.htm
[EIJIRO-terms]: https://www.eijiro.jp/kiyaku.htm
[Emacs init file]: https://www.gnu.org/software/emacs/manual/html_node/emacs/Init-File.html
[GPLv3]: https://www.gnu.org/licenses/gpl-3.0.html
[MELPA]: https://melpa.org/#/getting-started
[ripgrep]: https://github.com/BurntSushi/ripgrep
[vui]: https://github.com/d12frosted/vui.el
[英辞郎 on the WEB]: https://eow.alc.co.jp/

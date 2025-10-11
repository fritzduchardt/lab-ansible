#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/utils.sh"

usage() {
  echo """
Usage: $0 [OPTIONS]

Convert CV markdown file to PDF using pandoc with LaTeX template

OPTIONS:
    -i, --input FILE       Input markdown file (required)
    -o, --output FILE      Output PDF file (required)
    -t, --template FILE    LaTeX template file (default: template.tex)
    -e, --engine ENGINE    PDF engine to use (default: lualatex)
    -h, --help             Show this help message

EXAMPLES:
    # Convert with all required parameters
    $0 -i CV-English.md -o test.pdf -t template.tex

    # Use different PDF engine
    $0 -i my-cv.md -o my-cv.pdf -t template.tex -e xelatex

    # Use custom template and output
    $0 -i CV-English.md -t custom-template.tex -o output.pdf
"""
}

convert_cv() {
  local input_file="$1"
  local output_file="$2"
  local template_file="$3"
  local pdf_engine="$4"

  log::info "Converting CV from markdown to PDF"
  log::info "Input: $input_file"
  log::info "Output: $output_file"
  log::info "Template: $template_file"
  log::info "PDF Engine: $pdf_engine"

  lib::exec pandoc "$input_file" -o "$output_file" --template="$template_file" --pdf-engine="$pdf_engine"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log::error "Pandoc failed with exit code $rc"
    return $rc
  fi

  if [[ -f "$output_file" ]]; then
    log::info "Successfully created PDF: $output_file"
    return 0
  else
    log::error "Failed to create PDF file"
    return 1
  fi
}

main() {
  local input_file=""
  local output_file=""
  local template_file="${template_file:-template.tex}"
  local pdf_engine="${pdf_engine:-lualatex}"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -i|--input)
        input_file="$2"
        shift
        shift
        ;;
      -o|--output)
        output_file="$2"
        shift
        shift
        ;;
      -t|--template)
        template_file="$2"
        shift
        shift
        ;;
      -e|--engine)
        pdf_engine="$2"
        shift
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log::error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$input_file" ]]; then
    log::warn "Input file not specified"
    usage
    exit 1
  fi

  if [[ -z "$output_file" ]]; then
    output_file="${input_file%.md}.pdf"
    log::warn "Output file not specified"
    usage
    exit 1
  fi

  if [[ ! -f "$input_file" ]]; then
    log::error "Input file not found: $input_file"
    exit 1
  fi

  if [[ ! -f "$template_file" ]]; then
    log::error "Template file not found: $template_file"
    exit 1
  fi

  convert_cv "$input_file" "$output_file" "$template_file" "$pdf_engine"
}

main "$@"

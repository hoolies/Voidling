#!/usr/bin/env python3
"""Convert CSV data copied to clipboard to an HTML table."""

import pyperclip


def copy_to_clipboard(text: str):
    """Copy the given text to the system clipboard."""
    return pyperclip.copy(text)


def paste_from_clipboard() -> str:
    """Paste and return the text from the system clipboard."""
    return pyperclip.paste()


def paste_to_html(csv_paste: str) -> str:
    """Convert a CSV file to an HTML table."""
    paste = csv_paste.strip().splitlines()
    headers = paste[0].split(",")
    rows = [line.split(",") for line in paste[1:]]
    html_output = "<table>\n"
    html_output += (
        "  <tr>" + "".join(f"<th>{header}</th>" for header in headers) + "</tr>\n"
    )
    for row in rows:
        html_output += (
            "  <tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>\n"
        )
    html_output += "</table>"
    return html_output


def main() -> None:
    """Main function to convert clipboard CSV to HTML and copy back."""
    csv = paste_from_clipboard()
    output = paste_to_html(csv)
    copy_to_clipboard(output)
    print(output)


if __name__ == "__main__":
    main()

# End of file

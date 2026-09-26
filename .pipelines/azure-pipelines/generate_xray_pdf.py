import json
import sys
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak
from reportlab.lib.styles import getSampleStyleSheet

json_file = sys.argv[1]
pdf_file = sys.argv[2]

with open(json_file, "r") as f:
    data = json.load(f)

doc = SimpleDocTemplate(pdf_file)
styles = getSampleStyleSheet()

content = []

content.append(Paragraph("JFrog Xray Scan Report", styles["Title"]))
content.append(Spacer(1, 12))

content.append(
    Paragraph(f"Image: {data.get('artifact', 'Unknown')}", styles["Normal"])
)
content.append(Spacer(1, 10))

# Dump JSON contents into readable PDF
content.append(Paragraph("Scan Results", styles["Heading2"]))
content.append(Spacer(1, 10))

json_text = json.dumps(data, indent=2)

for line in json_text.splitlines():
    content.append(Paragraph(line.replace(" ", "&nbsp;"), styles["Code"]))

doc.build(content)

print(f"PDF generated: {pdf_file}")
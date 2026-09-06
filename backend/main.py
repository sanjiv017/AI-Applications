import io
import json
import os
import re
import traceback
from typing import List
from docx import Document
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from groq import Groq
import pdfplumber
from pydantic import BaseModel, Field

load_dotenv()

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

GROQ_API_KEY = os.getenv("GROQ_API_KEY", "").strip().strip('"').strip("'")
if not GROQ_API_KEY:
    # Fallback to check if set under previous variable name
    GROQ_API_KEY = os.getenv("GEMINI_API_KEY", "").strip().strip('"').strip("'")

client = Groq(api_key=GROQ_API_KEY)
# Fast, free, high-performance model on Groq
GROQ_MODEL = "openai/gpt-oss-120b"

class MetricScore(BaseModel):
    name: str
    weight: float
    score: float = Field(description="Score from 0 to 100")
    reasoning: str

class CandidateEvaluation(BaseModel):
    candidate_name: str
    metrics: List[MetricScore]
    composite_score: float = Field(description="Weighted sum: sum(score * weight)")
    strengths: List[str]
    red_flags: List[str]

def extract_text(file_bytes: bytes, filename: str) -> str:
    name = filename.lower()
    if name.endswith(".docx"):
        doc = Document(io.BytesIO(file_bytes))
        return "\n".join([p.text for p in doc.paragraphs if p.text])
    elif name.endswith(".pdf"):
        with pdfplumber.open(io.BytesIO(file_bytes)) as pdf:
            return "\n".join([page.extract_text() or "" for page in pdf.pages])
    return ""

@app.get("/")
def read_root():
    return {"status": "backend running with Groq API", "model": GROQ_MODEL}

@app.post("/shortlist")
@app.post("/shortlist/")
async def shortlist_candidates(
    top_n: int = Form(...),
    jd_file: UploadFile = File(...),
    resume_files: List[UploadFile] = File(...),
):
    if not GROQ_API_KEY:
        raise HTTPException(status_code=500, detail="GROQ_API_KEY is not configured.")

    try:
        jd_bytes = await jd_file.read()
        jd_text = extract_text(jd_bytes, jd_file.filename)
        evaluations = []

        for resume in resume_files:
            resume_bytes = await resume.read()
            resume_text = extract_text(resume_bytes, resume.filename)

            prompt = f"""
            Evaluate this resume strictly against the Job Description.
            Return a JSON object strictly following this structure:
            {{
              "candidate_name": "Full Name",
              "metrics": [
                {{"name": "Hard Skill Alignment", "weight": 0.20, "score": 85.0, "reasoning": "..."}},
                {{"name": "Experience Relevance", "weight": 0.15, "score": 80.0, "reasoning": "..."}},
                {{"name": "Seniority & Scope", "weight": 0.10, "score": 75.0, "reasoning": "..."}},
                {{"name": "Educational Qualification", "weight": 0.10, "score": 90.0, "reasoning": "..."}},
                {{"name": "Soft Skills & Leadership", "weight": 0.10, "score": 70.0, "reasoning": "..."}},
                {{"name": "Quantifiable Impact", "weight": 0.10, "score": 80.0, "reasoning": "..."}},
                {{"name": "Tool & Platform Stack", "weight": 0.10, "score": 85.0, "reasoning": "..."}},
                {{"name": "Career Continuity", "weight": 0.05, "score": 90.0, "reasoning": "..."}},
                {{"name": "Domain Experience", "weight": 0.05, "score": 75.0, "reasoning": "..."}},
                {{"name": "Communication Quality", "weight": 0.05, "score": 85.0, "reasoning": "..."}}
              ],
              "composite_score": 81.5,
              "strengths": ["string", "string"],
              "red_flags": ["string"]
            }}

            Ensure composite_score is the exact weighted sum of the 10 metric scores.

            Job Description:
            {jd_text}

            Resume:
            {resume_text}
            """

            chat_completion = client.chat.completions.create(
                messages=[
                    {
                        "role": "system",
                        "content": "You are an expert technical recruiter. You only output valid JSON with no markdown wrapping or preamble."
                    },
                    {
                        "role": "user",
                        "content": prompt
                    }
                ],
                model=GROQ_MODEL,
                temperature=0.1,
                response_format={"type": "json_object"}
            )

            raw_text = chat_completion.choices[0].message.content.strip()
            clean_text = re.sub(r"^```(?:json)?\s*|```$", "", raw_text, flags=re.MULTILINE).strip()
            parsed_eval = CandidateEvaluation.model_validate_json(clean_text)
            evaluations.append(parsed_eval)

        evaluations.sort(key=lambda x: x.composite_score, reverse=True)
        return {
            "total_processed": len(evaluations),
            "shortlisted": [e.model_dump() for e in evaluations[:top_n]],
        }

    except Exception as exc:
        print("ERROR IN GROQ SHORTLIST ROUTE:")
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(exc))

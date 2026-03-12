# UI Fix Proposal: Terminal Rendering Failures

## Overview
Based on a review of recent UI captures (`bad1.png`, `bad2.png`, `bad_example.png`, and `bad_again.png`), the application is experiencing critical rendering failures in the terminal view. The current implementation renders the app unusable for standard CLI operations. 

This document outlines the specific issues identified so they can be addressed by the development team.

## Identified Issues

### 1. Cumulative Rendering (The "Ghosting" Effect)
**Symptom:** The terminal view is not clearing its buffer or background before drawing the next frame. New text is painted directly over old text.
**Impact:** Creates an unreadable, stacked mess of multiple commands and directory listings.
**Action Required:** Ensure the terminal drawing lifecycle properly clears the screen or relevant regions before rendering new frames. The view must not function as an append-only visual log.

### 2. Failure to Handle Terminal "Clear" Signals and TUI Elements
**Symptom:** Complex TUI (Text User Interface) elements (like boxes and highlights) and terminal instructions to move the cursor or clear specific regions are being ignored.
**Impact:** Interactive terminal applications (like `top`, `vim`, or complex scripts) render incorrectly, breaking layout and functionality.
**Action Required:** Verify that the UI layer correctly interprets and executes all cursor movement, screen clearing, and region clearing escape sequences provided by the underlying terminal engine (SwiftTerm).

### 3. Coordinate System & Grid Mismatch
**Symptom:** Text alignment shifts horizontally and vertically. 
**Impact:** Text overlaps because the physical rendering doesn't match the logical grid. For example, rendering to "Line 10" overlaps "Line 9".
**Action Required:** Strictly enforce the grid. Ensure that the terminal rows and columns perfectly match the pixel dimensions of the mobile screen, and that line height is strictly locked to the font metrics.

### 4. Transparency and Layering Issues
**Symptom:** Background views or previous terminal states appear to bleed through the current view.
**Impact:** Reduces contrast and readability, contributing to visual clutter.
**Action Required:** Provide a solid, opaque background canvas for the terminal view. The CLI text must be the primary focus without interference from underlying layers.

### 5. Safe Area Neglect
**Symptom:** The top header ("My Mac" and the Disconnect button) floats over the terminal content, obscuring the top few lines of the terminal buffer.
**Impact:** Users cannot read or interact with the top lines of their terminal session.
**Action Required:** Respect the device safe areas and inset the terminal buffer appropriately. The first line of terminal output must never be hidden by UI chrome or hardware features like the Dynamic Island.

## Summary
The UI layer is currently treating the terminal stream as a continually growing text label rather than simulating a fixed-grid hardware terminal. Resolving the drawing lifecycle, enforcing the grid, and respecting standard terminal control sequences are prerequisites for shipping this feature.
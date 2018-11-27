-- WARNING: Automatically generated from "ui/style.css"
-- See executable `generate-ui`
{-# Language QuasiQuotes #-}
module UI.Style where

import Text.RawString.QQ

source :: String
source = "style.css"

content :: String
content = [r|

.annot {
  font-weight: bold;
}

.value-box {
  display: none;
  margin: 2px;
}

.vis-step.vis-cs {
  display: inline-block
}

.value {
  background-color: #fc6;
  border: 1px solid black;
  border-radius: 3px;
  color: black;
  padding-left: 2px;
  padding-right: 2px;
  margin: 2px;
}

.code {
  border: 1px solid black;
  background-color: #eee;
  padding: 1em;
  white-space: pre;
  font-family: monospace;
}

.line-no {
  display: inline-block;
  width: 2em;
  text-align: right;
  font-size: 10px;
  color: #999;
  margin-right: 1em;
}

.line {
  margin-bottom: 2px;
}

.line:hover {
  background-color: #ccc;
}

.marked.line {
  background-color: #ccc;
}


.call-site {
  cursor: pointer;
}

.marked.call-site {
  background-color: #fc6;
}

.active.call-site {
  box-shadow: 1px 1px 5px 1px #999;
  padding: 2px;
}

.step-button {
  background-color: orange;
  margin: 2px;
  cursor: pointer;
  border: 1px solid 0;
}


|]

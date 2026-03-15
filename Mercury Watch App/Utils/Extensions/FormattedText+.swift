//
//  FormattedText+.swift
//  Mercury Watch App
//
//  Created by Alessandro Alberti on 31/05/24.
//

import TDLibKit
import SwiftUI

extension FormattedText {
    var attributedString: AttributedString {
        
        var resultString = AttributedString(text)
        
        for entity in entities {
            
            let nsRange = range(for: text, offset: entity.offset, length: entity.length)
            guard let range = Range(nsRange, in: resultString) else {
                return resultString
            }
            
            switch entity.type {
            case .textEntityTypeBold:
                resultString[range].font = .system(.body).bold()
            case .textEntityTypeItalic:
                resultString[range].font = .system(.body).italic()
            case .textEntityTypeCode:
                resultString[range].font = .system(.body).monospaced()
            case .textEntityTypeUnderline:
                resultString[range].underlineStyle = .single
            case .textEntityTypeStrikethrough:
                resultString[range].strikethroughStyle = .single
            case .textEntityTypeMention:
                resultString[range].foregroundColor = .blue
            case .textEntityTypeUrl:
                let urlString = String(text[Range(nsRange, in: text)!])
                if let url = URL(string: urlString) {
                    resultString[range].link = url
                    resultString[range].foregroundColor = .blue
                }
            case .textEntityTypeTextUrl(let textUrl):
                if let url = URL(string: textUrl.url) {
                    resultString[range].link = url
                    resultString[range].foregroundColor = .blue
                }
            case .textEntityTypeSpoiler:
                resultString.characters.replaceSubrange(range, with: getRandomBraille(length: entity.length))
            case .textEntityTypeBlockQuote:
                let quote = String(resultString[range].characters)
                resultString.characters.replaceSubrange(range, with: "❝\(quote)❞")
            default:
                break
            }
        }
        return resultString
    }
    
    func getRandomBraille(length: Int) -> String {
        let braille = "⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏⠐⠑⠒⠓⠔⠕⠖⠗⠘⠙⠚⠛⠜⠝⠞⠟⠠⠡⠢⠣⠤⠥⠦⠧⠨⠩⠪⠫⠬⠭⠮⠯⠰⠱⠲⠳⠴⠵⠶⠷⠸⠹⠺⠻⠼⠽⠾⠿"
        var string = ""
        
        for _ in 0...length - 1{
            let randomIndex = Int.random(in: 0...braille.count - 1)
            let index = braille.index(braille.startIndex, offsetBy: randomIndex)
            string.append(braille[index])
        }
        return string
    }
    
    private func range(for string: String, offset: Int, length: Int) -> NSRange {
        let start = text.utf16.index(text.startIndex, offsetBy: offset)
        let end = text.utf16.index(start, offsetBy: length)
        return NSRange(start..<end, in: text)
    }
    
}

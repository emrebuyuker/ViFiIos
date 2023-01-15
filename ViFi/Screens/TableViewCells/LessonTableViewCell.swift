//
//  LessonTableViewCell.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit

class LessonTableViewCell: UITableViewCell {

    @IBOutlet weak var lessonNameLabel: UILabel!
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
